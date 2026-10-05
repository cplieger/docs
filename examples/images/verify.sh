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
  "$pinned" | jq -r '.payload' | head -n 1 | base64 -d | jq '.predicate.packages | length'
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
tags="$(gh api --paginate "repos/cplieger/${app}/tags?per_page=100" \
  --jq ".[] | select(.commit.sha == \"${commit}\") | .name")"
# grep exits 1 when no tag matches, which means no release. Any other failure stops the script.
release="$(grep -m 1 -E '^v[0-9]+\.[0-9]+\.[0-9]+$' <<<"$tags" || [ "$?" -eq 1 ])"
if [ -z "$release" ]; then
  echo "No release was built from commit $commit, so no release file describes this image."
else
  echo "Release built from the same commit: $release"
  dir="$(mktemp -d)"
  gh release download "$release" --repo "cplieger/${app}" --pattern 'sbom.spdx.json*' --dir "$dir"
  cosign verify-blob \
    --bundle "$dir/sbom.spdx.json.sigstore.json" \
    --certificate-oidc-issuer https://token.actions.githubusercontent.com \
    --certificate-identity-regexp '^https://github\.com/cplieger/ci/\.github/workflows/docker-release\.yaml@' \
    --certificate-github-workflow-repository "cplieger/${app}" \
    --certificate-github-workflow-sha "$commit" \
    "$dir/sbom.spdx.json"
fi
# endregion: release-sbom
