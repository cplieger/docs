#!/usr/bin/env bash
# Runs examples/images/verify.sh against published images, then proves each
# check refuses an image or a release file it was not given, and that a
# release file is matched to an image by its packages and their versions.
set -euo pipefail
# shellcheck source-path=SCRIPTDIR
source "$(dirname "$0")/../lib.sh"

VERIFY="$DOCS_ROOT/examples/images/verify.sh"
ISSUER="https://token.actions.githubusercontent.com"
IDENTITY='^https://github\.com/cplieger/ci/\.github/workflows/docker-release\.yaml@'
IMAGE="ghcr.io/cplieger/web-terminal-server:latest"
APP="knell"
OUT_FILE="$(mktemp)"
SCRATCH="$(mktemp -d)"
remove_scratch() {
  rm -rf "$OUT_FILE" "$SCRATCH"
}
trap remove_scratch EXIT

# run_verify ARGS... runs verify.sh, prints its output, and keeps it in OUT_FILE.
run_verify() {
  local rc=0
  bash "$VERIFY" "$@" >"$OUT_FILE" 2>&1 || rc=$?
  cat "$OUT_FILE"
  [ "$rc" -eq 0 ] || die "verify.sh $* failed"
}

# picked prints the release the last verify.sh run matched, or nothing.
picked() {
  sed -n 's/^Release that published this build: //p' "$OUT_FILE"
}

# digest_of TAG prints the digest a tag of $APP names.
digest_of() {
  docker buildx imagetools inspect "ghcr.io/cplieger/$APP:$1" --format '{{.Manifest.Digest}}'
}

# source_of TAG prints the commit the signed bill of materials of a tag of $APP names.
source_of() {
  gh attestation verify "oci://ghcr.io/cplieger/$APP:$1" --repo "cplieger/$APP" --bundle-from-oci \
    --predicate-type https://spdx.dev/Document \
    --signer-workflow cplieger/ci/.github/workflows/docker-release.yaml \
    --format json --jq '.[0].verificationResult.signature.certificate.sourceRepositoryDigest'
}

# download TAG fetches the release file of a tag of $APP into $SCRATCH/TAG, once.
download() {
  [ -f "$SCRATCH/$1/sbom.spdx.json" ] && return 0
  mkdir -p "$SCRATCH/$1"
  gh release download "$1" --repo "cplieger/$APP" --pattern 'sbom.spdx.json*' --dir "$SCRATCH/$1"
}

# expect_accepted RELEASE says the last run matched RELEASE and accepted its file.
expect_accepted() {
  [ "$(picked)" = "$1" ] || die "verify.sh matched '$(picked)', not $1"
  grep -qx "Verified OK" "$OUT_FILE" || die "verify.sh did not check the signature of the file of $1"
  grep -qx "The file of $1 lists the same packages as the list signed into this image." "$OUT_FILE" \
    || die "verify.sh did not compare the file of $1 with the image"
}

# stable_releases APP prints the stable vX.Y.Z releases of APP, newest first,
# each as "<created_at> <tag>".
stable_releases() {
  gh api --paginate "repos/cplieger/$1/releases?per_page=100" \
    --jq '.[] | select((.draft or .prerelease) | not) | select(.tag_name | test("^v[0-9]+[.][0-9]+[.][0-9]+$")) | "\(.created_at) \(.tag_name)"' \
    | sort -r
}

listing="$(stable_releases "$APP")"
releases="$(cut -d ' ' -f 2 <<<"$listing")"
[ -n "$releases" ] || die "$APP has no release"
newest="$(head -n 1 <<<"$releases")"
# The searches for a past event run oldest first, so newer releases add no
# work before a match they already found.
oldest_first="$(tac <<<"$releases")"

exporter_major="$(stable_releases plex-exporter | head -n 1 | cut -d ' ' -f 2 | cut -d . -f 1)"
[ -n "$exporter_major" ] || die "plex-exporter has no release"
for target in "web-terminal-server latest" "plex-exporter $exporter_major"; do
  read -r app tag <<<"$target"
  run_verify "$app" "$tag"
  [ -n "$(picked)" ] || die "no release was matched with $app:$tag, which only a release moves"
  grep -qx "The file of $(picked) lists the same packages as the list signed into this image." "$OUT_FILE" \
    || die "verify.sh did not compare the file of $(picked) with $app:$tag"
  pass "every check passes for $app:$tag, matched with the file of $(picked)"
done

# A promoted release's tag names a later commit than the one its image's
# signed bill of materials names, so a lookup by that commit misses it.
# Only a build no other release names has one release the run must match.
digests="$SCRATCH/digests"
for release in $releases; do
  printf '%s %s\n' "$(digest_of "$release" 2>/dev/null || echo unreadable)" "$release"
done >"$digests"
promoted=""
for release in $releases; do
  promoted_digest="$(awk -v r="$release" '$2 == r { print $1 }' "$digests")"
  [ "$promoted_digest" != unreadable ] || continue
  [ "$(awk -v d="$promoted_digest" '$1 == d' "$digests" | wc -l)" -eq 1 ] || continue
  built_from="$(source_of "$release")"
  tagged="$(gh api "repos/cplieger/$APP/commits/$release" --jq .sha)"
  if [ "$built_from" != "$tagged" ] \
    && [ "$(gh api "repos/cplieger/$APP/compare/$built_from...$tagged" --jq .status)" = ahead ]; then
    promoted="$release"
    break
  fi
done
[ -n "$promoted" ] || die "$APP has no release that alone promoted a build"
run_verify "$APP" "$promoted"
[ "$(digest_of "$(picked)")" = "$promoted_digest" ] || die "verify.sh matched $(picked), which published another build"
expect_accepted "$promoted"
pass "the build $promoted promoted is checked against the file of $promoted"
match="$promoted"

# An older major version must never be matched with the newest release.
older=""
for major in $(cut -d . -f 1 <<<"$releases" | uniq); do
  [ "$major" != "${newest%%.*}" ] || continue
  if digest_of "$major" >/dev/null 2>&1; then
    older="$major"
    break
  fi
done
[ -n "$older" ] || die "$APP has no older major version with an image"
run_verify "$APP" "$older"
older_match="$(picked)"
case "$older_match" in
  "$newest") die "$APP:$older was matched with the newest release, $newest" ;;
  "" | "$older".*) pass "$APP:$older is matched with ${older_match:-no release}, never with $newest" ;;
  *) die "$APP:$older was matched with $older_match" ;;
esac

# A version tag a later build took over must not be matched with its own
# release, whose file describes the build it first named.
moved=""
for release in $oldest_first; do
  dated="$(grep " $release\$" <<<"$listing" | cut -d ' ' -f 1)"
  committed="$(gh api "repos/cplieger/$APP/commits/$(source_of "$release")" --jq .commit.committer.date)"
  if [[ "$dated" < "$committed" ]]; then
    moved="$release"
    break
  fi
done
[ -n "$moved" ] || die "$APP has no version tag that a later build took over"
run_verify "$APP" "$moved"
moved_match="$(picked)"
[ "$moved_match" != "$moved" ] || die "$APP:$moved was matched with the release it moved from"
pass "$APP:$moved, moved to a later build, is matched with ${moved_match:-no release}, never with $moved"

# A file restored to a release later is signed by the run that restored it,
# which names another commit than the release's own.
restored=""
for release in $oldest_first; do
  download "$release"
  tagged="$(gh api "repos/cplieger/$APP/commits/$release" --jq .sha)"
  if ! cosign verify-blob --bundle "$SCRATCH/$release/sbom.spdx.json.sigstore.json" \
    --certificate-oidc-issuer "$ISSUER" --certificate-identity-regexp "$IDENTITY" \
    --certificate-github-workflow-repository "cplieger/$APP" \
    --certificate-github-workflow-sha "$tagged" \
    "$SCRATCH/$release/sbom.spdx.json" >/dev/null 2>&1; then
    restored="$release"
    break
  fi
done
[ -n "$restored" ] || die "$APP has no release whose file a later run restored"
run_verify "$APP" "$restored"
expect_accepted "$restored"
pass "the file of $restored, restored by a later run, is checked against the build of $restored"

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

# with_swapped_file REPO TAG runs verify.sh on the promoted build while a gh
# shim downloads the release file of TAG in REPO instead of the one asked for.
mkdir -p "$SCRATCH/gh-shim"
cat >"$SCRATCH/gh-shim/gh" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-} ${2:-} ${4:-}" = "release download --repo" ]; then
  printf '%s %s\n' "$5" "$3" >>"$SHIM_LOG"
  set -- release download "$SWAP_TAG" --repo "$SWAP_REPO" "${@:6}"
fi
exec "$REAL_GH" "$@"
EOF
chmod +x "$SCRATCH/gh-shim/gh"
with_swapped_file() {
  rm -f "$SCRATCH/gh-shim/calls"
  local rc=0
  REAL_GH="$(command -v gh)" SWAP_REPO="$1" SWAP_TAG="$2" SHIM_LOG="$SCRATCH/gh-shim/calls" \
  PATH="$SCRATCH/gh-shim:$PATH" bash "$VERIFY" "$APP" "$promoted" >"$OUT_FILE" 2>&1 || rc=$?
  [ "$(cat "$SCRATCH/gh-shim/calls")" = "cplieger/$APP $match" ] || die "verify.sh did not download the file of $match"
  return "$rc"
}

# Every app's release file is signed by the same workflow, so the app's
# repository is what refuses another app's file.
other_app="web-terminal-server"
other_app_release="$(gh api "repos/cplieger/$other_app/releases/latest" --jq .tag_name)"
if with_swapped_file "cplieger/$other_app" "$other_app_release"; then
  cat "$OUT_FILE"
  die "the file of $other_app $other_app_release was accepted as the file of $match"
fi
if grep -qx "Verified OK" "$OUT_FILE" || grep -q "^The file of " "$OUT_FILE"; then
  cat "$OUT_FILE"
  die "the signature of the file of $other_app $other_app_release was not what refused it"
fi
pass "the file of $other_app $other_app_release is refused by its signature as the file of $APP $match"

# The file of another release is signed by the same app's release workflow,
# so only the comparison with the list signed into the image can refuse it.
# The test picks one whose packages or versions truly differ.
list='[.packages[] | [.name, .versionInfo]] | sort'
download "$match"
other=""
for release in $releases; do
  [ "$release" != "$match" ] || continue
  download "$release"
  if [ "$(jq -c "$list" "$SCRATCH/$release/sbom.spdx.json")" != "$(jq -c "$list" "$SCRATCH/$match/sbom.spdx.json")" ]; then
    other="$release"
    break
  fi
done
[ -n "$other" ] || die "every release of $APP lists the packages of $match"
if with_swapped_file "cplieger/$APP" "$other"; then
  cat "$OUT_FILE"
  die "the file of $other was accepted as the file of $match"
fi
grep -qx "Verified OK" "$OUT_FILE" || {
  cat "$OUT_FILE"
  die "verify.sh refused the file of $other before checking its signature"
}
grep -qx "The file of $match does not list the packages signed into this image." "$OUT_FILE" || {
  cat "$OUT_FILE"
  die "verify.sh refused the file of $other before comparing it with the image"
}
pass "the file of $other is refused as the file of $match"

# with_listed_releases MODE TAG... runs verify.sh on the promoted build while a
# gh shim adds releases TAG..., dated at the build's commit, to the release
# listing. MODE "added" keeps the real releases, MODE "only" drops them.
mkdir -p "$SCRATCH/list-shim"
cat >"$SCRATCH/list-shim/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-} ${2:-} ${4:-}" = "api --paginate --jq" ] && [ "${3:-}" = "repos/cplieger/$SHIM_APP/releases?per_page=100" ]; then
  printf 'listed\n' >>"$SHIM_LOG"
  if [ "$SHIM_MODE" = only ]; then
    printf '[]'
  else
    "$REAL_GH" api --paginate "$3"
  fi | jq -rs --argjson fake "$SHIM_FAKE" "add + \$fake | $5"
  exit 0
fi
exec "$REAL_GH" "$@"
EOF
chmod +x "$SCRATCH/list-shim/gh"
built_on="$(gh api "repos/cplieger/$APP/commits/$(source_of "$promoted")" --jq .commit.committer.date)"
match_dated="$(grep " $match\$" <<<"$listing" | cut -d ' ' -f 1)"
[[ "$built_on" < "$match_dated" ]] || die "$match is not dated after the commit of the build it published"
with_listed_releases() {
  local mode="$1" fake
  shift
  fake="$(printf '%s\n' "$@" | jq -Rn --arg date "$built_on" \
    '[inputs | {tag_name: ., created_at: $date, draft: false, prerelease: false}]')"
  rm -f "$SCRATCH/list-shim/calls"
  local rc=0
  REAL_GH="$(command -v gh)" SHIM_APP="$APP" SHIM_MODE="$mode" SHIM_FAKE="$fake" SHIM_LOG="$SCRATCH/list-shim/calls" \
  PATH="$SCRATCH/list-shim:$PATH" bash "$VERIFY" "$APP" "$promoted" >"$OUT_FILE" 2>&1 || rc=$?
  [ "$(cat "$SCRATCH/list-shim/calls" 2>/dev/null)" = listed ] || die "the gh shim did not serve the release listing once"
  return "$rc"
}

# A nested module's release, tagged <dir>/vX.Y.Z, names no image, and a
# version tag GHCR does not have names no image either.
nested="tools/v1.2.3"
missing="v999999.0.0"
if docker buildx imagetools inspect "ghcr.io/cplieger/$APP:$missing" >/dev/null 2>&1; then
  die "ghcr.io/cplieger/$APP:$missing exists, so it cannot stand for a missing image"
fi
if ! with_listed_releases added "$nested" "$missing"; then
  cat "$OUT_FILE"
  die "a release with no image stopped the search before $match"
fi
expect_accepted "$match"
pass "releases $nested and $missing, which name no image, do not stop the search before $match"

if ! with_listed_releases only "$nested"; then
  cat "$OUT_FILE"
  die "verify.sh read an image for the release $nested of a nested module"
fi
grep -qx "No release published this build, so no release file describes it." "$OUT_FILE" || {
  cat "$OUT_FILE"
  die "verify.sh matched a release with the build $promoted promoted when only $nested was listed"
}
pass "the release $nested of a nested module is never read as an image"

if with_listed_releases only "$nested" "$missing"; then
  cat "$OUT_FILE"
  die "verify.sh reported no release when the image of $missing could not be read"
fi
grep -qx "Could not read the image of $missing, so it is unknown which release published this build." "$OUT_FILE" || {
  cat "$OUT_FILE"
  die "verify.sh did not name the release whose image it could not read"
}
pass "an unreadable release image with no other match is an error, not a report of no release"

# with_edited_list NAME FILTER runs verify.sh on the promoted build while a
# cosign shim applies the jq FILTER to the list signed into the image.
with_edited_list() {
  local dir="$SCRATCH/cosign-$1"
  mkdir -p "$dir"
  printf '.payload |= (@base64d | fromjson | .predicate |= (%s) | tojson | @base64)\n' "$2" >"$dir/edit.jq"
  cat >"$dir/cosign" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = "verify-attestation" ]; then
  printf 'edited\n' >>"$SHIM_LOG"
  "$REAL_COSIGN" "$@" | jq -c -f "$EDIT"
  exit 0
fi
exec "$REAL_COSIGN" "$@"
EOF
  chmod +x "$dir/cosign"
  local rc=0
  REAL_COSIGN="$(command -v cosign)" EDIT="$dir/edit.jq" SHIM_LOG="$dir/calls" PATH="$dir:$PATH" \
    bash "$VERIFY" "$APP" "$promoted" >"$OUT_FILE" 2>&1 || rc=$?
  [ "$(grep -c edited "$dir/calls")" -eq 2 ] || die "the cosign shim did not edit both reads of the signed list"
  return "$rc"
}

# A promoting release that scanned the image again, as older ones did, carries
# a file that can differ from the signed list in its date, document name,
# scanner version and extra references, none of which the comparison reads.
rescan='.creationInfo.created = "2000-01-01T00:00:00Z"
  | .documentNamespace = "https://example.invalid/rescan"
  | .creationInfo.creators = ["Tool: syft-0.0.0-edited"]
  | .creationInfo.licenseListVersion = "0.0"
  | .packages[0].externalRefs = ((.packages[0].externalRefs // []) + [{"referenceCategory": "SECURITY", "referenceType": "cpe23Type", "referenceLocator": "cpe:2.3:a:example:edited:0:*:*:*:*:*:*:*"}])'
if ! with_edited_list rescan "$rescan"; then
  cat "$OUT_FILE"
  die "a file that differs from the image's list only in its date, name, scanner version and references was refused"
fi
expect_accepted "$match"
pass "a file that differs from the image's list only in its date, name, scanner version and references is accepted"

if with_edited_list version '.packages[0].versionInfo = "0.0.0-edited"'; then
  cat "$OUT_FILE"
  die "a file listing another version of a package was accepted"
fi
grep -qx "The file of $match does not list the packages signed into this image." "$OUT_FILE" || {
  cat "$OUT_FILE"
  die "verify.sh refused the edited list before comparing it with the file of $match"
}
pass "a file listing another version of a package than the image is refused"
