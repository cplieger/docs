#!/usr/bin/env bash
# Runs examples/images/verify.sh against published images, then proves each
# check refuses an image or a release file it was not given.
set -euo pipefail
# shellcheck source-path=SCRIPTDIR
source "$(dirname "$0")/../lib.sh"

VERIFY="$DOCS_ROOT/examples/images/verify.sh"
ISSUER="https://token.actions.githubusercontent.com"
IDENTITY='^https://github\.com/cplieger/ci/\.github/workflows/docker-release\.yaml@'
IMAGE="ghcr.io/cplieger/web-terminal-server:latest"
OUT_FILE="$(mktemp)"
SBOM_DIR="$(mktemp -d)"
remove_scratch() {
  rm -rf "$OUT_FILE" "$SBOM_DIR"
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
