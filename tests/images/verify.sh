#!/usr/bin/env bash
# Runs examples/images/verify.sh against published images, then proves each
# check refuses an image or a release file it was not given and accepts a
# release file restored after publication.
set -euo pipefail
# shellcheck source-path=SCRIPTDIR
source "$(dirname "$0")/../lib.sh"

VERIFY="$DOCS_ROOT/examples/images/verify.sh"
ISSUER="https://token.actions.githubusercontent.com"
IDENTITY='^https://github\.com/cplieger/ci/\.github/workflows/docker-release\.yaml@'
IMAGE="ghcr.io/cplieger/web-terminal-server:latest"
OUT_FILE="$(mktemp)"
SBOM_DIR="$(mktemp -d)"
SHIM_DIR="$(mktemp -d)"
SIGN_SHIM_DIR="$(mktemp -d)"
remove_scratch() {
  rm -rf "$OUT_FILE" "$SBOM_DIR" "$SHIM_DIR" "$SIGN_SHIM_DIR"
}
trap remove_scratch EXIT

# run_verify ARGS... runs verify.sh, prints its output, and keeps it in OUT_FILE.
run_verify() {
  bash "$VERIFY" "$@" 2>&1 | tee "$OUT_FILE"
  [ "${PIPESTATUS[0]}" -eq 0 ] || die "verify.sh $* failed"
}

run_verify web-terminal-server
pass "every check passes for web-terminal-server:latest"
run_verify registry-stats v4
pass "every check passes for registry-stats:v4"

# The image of a release's own commit must be checked against that release's file.
release="$(gh release view --repo cplieger/knell --json tagName --jq .tagName)"
commit="$(gh api "repos/cplieger/knell/commits/$release" --jq .sha)"
run_verify knell "sha-$commit"
grep -qx "Release built from the same commit: $release" "$OUT_FILE" || die "verify.sh did not pick $release for its own commit"
grep -qx "Verified OK" "$OUT_FILE" || die "verify.sh did not check the file of $release"
pass "the build of $release is checked against the file of $release"

# An older major version must never be matched with the newest release.
run_verify knell v1
picked="$(sed -n 's/^Release built from the same commit: //p' "$OUT_FILE")"
case "$picked" in
  "" | v1.*) pass "knell:v1 is matched with ${picked:-no release}, never with $release" ;;
  *) die "knell:v1 was matched with $picked" ;;
esac

# must_fail DESCRIPTION COMMAND... passes only when COMMAND exits non-zero.
must_fail() {
  local what="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    die "$what was accepted"
  fi
  pass "$what is refused"
}

must_fail "a signature checked against another app's repository" \
  cosign verify --certificate-oidc-issuer "$ISSUER" --certificate-identity-regexp "$IDENTITY" \
  --certificate-github-workflow-repository cplieger/subflux "$IMAGE"
must_fail "a signature checked against another issuer" \
  cosign verify --certificate-oidc-issuer https://accounts.google.com --certificate-identity-regexp "$IDENTITY" \
  --certificate-github-workflow-repository cplieger/web-terminal-server "$IMAGE"
must_fail "a signature checked against another signing workflow" \
  cosign verify --certificate-oidc-issuer "$ISSUER" \
  --certificate-identity-regexp '^https://github\.com/cplieger/ci/\.github/workflows/release\.yaml@' \
  --certificate-github-workflow-repository cplieger/web-terminal-server "$IMAGE"
must_fail "a GitHub CLI check against another app's repository" \
  gh attestation verify "oci://$IMAGE" --repo cplieger/subflux --bundle-from-oci \
  --predicate-type https://spdx.dev/Document

gh release download "$release" --repo cplieger/knell --pattern 'sbom.spdx.json*' --dir "$SBOM_DIR"
must_fail "a release file checked against a build from another commit" \
  cosign verify-blob --bundle "$SBOM_DIR/sbom.spdx.json.sigstore.json" \
  --certificate-oidc-issuer "$ISSUER" --certificate-identity-regexp "$IDENTITY" \
  --certificate-github-workflow-repository cplieger/knell \
  --certificate-github-workflow-sha 0000000000000000000000000000000000000000 \
  "$SBOM_DIR/sbom.spdx.json"

# The file of an older release is signed by the same app's release workflow, so
# it passes the signature check without the commit; only the comparison with the
# list signed into the image can refuse it.
older="$(gh release list --repo cplieger/knell --exclude-drafts --exclude-pre-releases --limit 50 \
  --json tagName --jq '.[].tagName' | grep -m 1 -A 1 -x "$release" | tail -n 1)"
[ -n "$older" ] && [ "$older" != "$release" ] || die "knell has no release older than $release"
cat >"$SHIM_DIR/gh" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-} ${2:-}" = "release download" ]; then
  printf '%s\n' "$3" >>"$SHIM_LOG"
  set -- release download "$SWAP_TAG" "${@:4}"
fi
exec "$REAL_GH" "$@"
EOF
chmod +x "$SHIM_DIR/gh"
real_gh="$(command -v gh)"
if REAL_GH="$real_gh" SWAP_TAG="$older" SHIM_LOG="$SHIM_DIR/calls" PATH="$SHIM_DIR:$PATH" \
  bash "$VERIFY" knell "sha-$commit" >"$OUT_FILE" 2>&1; then
  cat "$OUT_FILE"
  die "the file of $older was accepted as the file of $release"
fi
[ "$(cat "$SHIM_DIR/calls")" = "$release" ] || die "verify.sh did not download the file of $release"
grep -qx "The file of $release is not the list signed into this image." "$OUT_FILE" || {
  cat "$OUT_FILE"
  die "verify.sh refused the file of $older before comparing it with the image"
}
pass "the file of $older is refused as the file of $release"

# A restored file differs from the original only in the commit its signature
# names, so the shim refuses just the commit-pinned check; the real file must
# then pass the unpinned check and the comparison with the image's list.
cat >"$SIGN_SHIM_DIR/cosign" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "verify-blob" ]; then
  for arg in "$@"; do
    if [ "$arg" = "--certificate-github-workflow-sha" ]; then
      printf 'pinned\n' >>"$SHIM_LOG"
      echo "shim: signed by a later run" >&2
      exit 1
    fi
  done
  printf 'unpinned\n' >>"$SHIM_LOG"
fi
exec "$REAL_COSIGN" "$@"
EOF
chmod +x "$SIGN_SHIM_DIR/cosign"
real_cosign="$(command -v cosign)"
if ! REAL_COSIGN="$real_cosign" SHIM_LOG="$SIGN_SHIM_DIR/calls" PATH="$SIGN_SHIM_DIR:$PATH" \
  bash "$VERIFY" knell "sha-$commit" >"$OUT_FILE" 2>&1; then
  cat "$OUT_FILE"
  die "the restored file of $release was refused"
fi
[ "$(tr '\n' ' ' <"$SIGN_SHIM_DIR/calls")" = "pinned unpinned " ] || die "verify.sh did not fall back to the unpinned check"
grep -qx "The file of $release was restored later, and it is the list signed into this image." "$OUT_FILE" || {
  cat "$OUT_FILE"
  die "verify.sh accepted the restored file of $release without comparing it with the image"
}
pass "a restored file of $release that is the image's list is accepted"
