#!/usr/bin/env bash
# Checks that a cplieger image was built and signed by its release workflow.
#   bash verify.sh <app> [tag]     for example: bash verify.sh knell v2
# Needs cosign, jq, the GitHub CLI logged in with "gh auth login", and Docker.
# Every check reads the build the tag names when the script starts, even if the tag moves meanwhile.
set -euo pipefail

# region: setup
app="${1:-knell}"
tag="${2:-latest}"
image="ghcr.io/cplieger/${app}:${tag}"
# endregion: setup

# region: digest
digest="$(docker buildx imagetools inspect "$image" --format '{{.Manifest.Digest}}')"
pinned="ghcr.io/cplieger/${app}@${digest}"
# endregion: digest
echo "Checking $image, which is $pinned"

# region: cosign-verify
cosign verify \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-identity-regexp '^https://github\.com/cplieger/ci/\.github/workflows/docker-release\.yaml@' \
  --certificate-github-workflow-repository "cplieger/${app}" \
  "$pinned" >/dev/null
# endregion: cosign-verify
echo "Signature: OK"

echo "Packages listed in the signed software bill of materials:"
# region: cosign-attestation
cosign verify-attestation --type spdxjson \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-identity-regexp '^https://github\.com/cplieger/ci/\.github/workflows/docker-release\.yaml@' \
  --certificate-github-workflow-repository "cplieger/${app}" \
  "$pinned" | jq -rs '.[0].payload' | base64 -d | jq '.predicate.packages | length'
# endregion: cosign-attestation

# region: gh-attestation
gh attestation verify "oci://${pinned}" \
  --repo "cplieger/${app}" \
  --bundle-from-oci \
  --predicate-type https://spdx.dev/Document \
  --signer-workflow cplieger/ci/.github/workflows/docker-release.yaml
# endregion: gh-attestation
echo "GitHub CLI check: OK"

trap 'rm -rf "${dir:-}"' EXIT
# region: source-commit
commit="$(gh attestation verify "oci://${pinned}" \
  --repo "cplieger/${app}" \
  --bundle-from-oci \
  --predicate-type https://spdx.dev/Document \
  --signer-workflow cplieger/ci/.github/workflows/docker-release.yaml \
  --format json --jq '.[0].verificationResult.signature.certificate.sourceRepositoryDigest')"
# endregion: source-commit
case "$commit" in
  *[!0-9a-f]* | "")
    echo "The signature names no source commit: '$commit'" >&2
    exit 1
    ;;
esac
echo "Built from commit $commit of cplieger/${app}"

# region: release-sbom
# A release's created_at is the date of its commit, not of its publication:
# https://docs.github.com/en/rest/releases/releases#get-the-latest-release
since="$(gh api "repos/cplieger/${app}/commits/${commit}" --jq '.commit.committer.date')"
candidates="$(gh api --paginate "repos/cplieger/${app}/releases?per_page=100" \
  --jq ".[] | select((.draft or .prerelease) | not) | select(.tag_name | test(\"^v[0-9]+[.][0-9]+[.][0-9]+$\")) | select(.created_at >= \"${since}\") | \"\(.created_at) \(.tag_name)\"" \
  | sort | cut -d ' ' -f 2)"
release=""
unread=""
for candidate in $candidates; do
  if ! published="$(docker buildx imagetools inspect "ghcr.io/cplieger/${app}:${candidate}" --format '{{.Manifest.Digest}}')"; then
    unread="$unread $candidate"
    continue
  fi
  if [ "$published" = "$digest" ]; then
    release="$candidate"
    break
  fi
done
if [ -z "$release" ] && [ -n "$unread" ]; then
  echo "Could not read the image of$unread, so it is unknown which release published this build." >&2
  exit 1
elif [ -z "$release" ]; then
  echo "No release published this build, so no release file describes it."
else
  echo "Release that published this build: $release"
  dir="$(mktemp -d)"
  gh release download "$release" --repo "cplieger/${app}" --pattern 'sbom.spdx.json*' --dir "$dir"
  cosign verify-blob \
    --bundle "$dir/sbom.spdx.json.sigstore.json" \
    --certificate-oidc-issuer https://token.actions.githubusercontent.com \
    --certificate-identity-regexp '^https://github\.com/cplieger/ci/\.github/workflows/docker-release\.yaml@' \
    --certificate-github-workflow-repository "cplieger/${app}" \
    "$dir/sbom.spdx.json"
  cosign verify-attestation --type spdxjson \
    --certificate-oidc-issuer https://token.actions.githubusercontent.com \
    --certificate-identity-regexp '^https://github\.com/cplieger/ci/\.github/workflows/docker-release\.yaml@' \
    --certificate-github-workflow-repository "cplieger/${app}" \
    "$pinned" | jq -rs '.[0].payload' | base64 -d | jq '.predicate' >"$dir/attested.json"
  packages='[.packages[] | {name, versionInfo}] | sort'
  jq -S "$packages" "$dir/sbom.spdx.json" >"$dir/release-packages.json"
  jq -S "$packages" "$dir/attested.json" >"$dir/image-packages.json"
  if ! cmp -s "$dir/release-packages.json" "$dir/image-packages.json"; then
    echo "The file of $release does not list the packages signed into this image." >&2
    exit 1
  fi
  echo "The file of $release lists the same packages as the list signed into this image."
fi
# endregion: release-sbom
