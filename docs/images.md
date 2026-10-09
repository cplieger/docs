# Image tags, updates and verification

This page explains which tag of a cplieger image to run and how updates reach you. It also shows how to check that an image was built by its release workflow. It is for anyone who runs a `ghcr.io/cplieger/*` or `docker.io/cplieger/*` image.

## Where the images are

Every image is published under the same name to two registries:

- GitHub Container Registry, as `ghcr.io/cplieger/<app>`
- Docker Hub, as `docker.io/cplieger/<app>`, or `cplieger/<app>` for short

Both carry the same builds, tags and signatures. Each image runs on `linux/amd64` and `linux/arm64`, and Docker picks the right one for your host. The GitHub page of each app links its packages and its releases.

## Which tag to use

Each release publishes these tags, on both registries:

| Tag | Example | Points to |
| --- | --- | --- |
| `latest` | `knell:latest` | The newest release |
| `vX` | `knell:v2` | The newest release with that major version |
| `vX.Y` | `knell:v2.2` | The newest release with that major and minor version |
| `vX.Y.Z` | `knell:v2.2.1` | One release |
| `sha-<commit>` | `knell:sha-<40 characters>` | The build of one commit of the app's repository |

For an image at version 1 or later, only a new major version needs action on your side, such as `v3` after `v2`. Its release notes say what to change. An image still at version 0, such as `v0.6`, can need a change in a minor version.

Use `vX` for a server you want to keep up to date without surprises. It moves to every new feature and fix within the major version you chose. It never moves to the next major version. For an image at version 0, use `v0.Y` instead. Use `latest` to try an image.

A `vX.Y.Z` tag names one version, but it can still move. After a rebuild, it can point to a newer build made from a later commit of the app, such as a base-image update. The version's release on GitHub, and the git tag it names, never move once published. A `sha-<commit>` tag stays on one commit of the app's code, so it never gets the app's later fixes. Only a digest names one build that never changes.

GitHub's package page also lists tags that start with `sha256-`. They hold signatures and attestations, not images, so do not run them.

## Pinning a digest

A digest is the fingerprint of one exact build, and it never changes. Pin it next to the tag to deploy that exact build until you choose to move. The image line then reads `image: ghcr.io/cplieger/knell:v2@sha256:<digest>`, with the digest in place of `<digest>`.

Docker then ignores the tag when it pulls and uses the digest. The tag stays in the line so you and your update tool can see which version line it belongs to. These lines save the digest of a tag in `$digest`, and the image name with that digest in `$pinned`:

<!-- include: examples/images/verify.sh#digest -->

```sh
digest="$(docker buildx imagetools inspect "$image" --format '{{.Manifest.Digest}}')"
pinned="ghcr.io/cplieger/${app}@${digest}"
```

<!-- /include -->

Here `$image` is the full image name with its tag, for example `ghcr.io/cplieger/knell:v2`. Run `echo "$digest"` to see the digest. It is the same on GitHub Container Registry and Docker Hub.

## How updates reach you

A container keeps running the build it started with until you pull and recreate it. With a tag and no digest, `docker compose pull`, then `docker compose up -d`, moves you to the newest build of that tag.

With a digest, an update tool moves the digest for you and shows you each change first:

- [Renovate](https://docs.renovatebot.com/docker/) reads compose files in a Git repository and opens a pull request for each new build and each new version. It can add digests to the image lines itself.
- [Dependabot](https://docs.github.com/en/code-security/dependabot/working-with-dependabot/dependabot-options-reference) updates image versions in compose files on GitHub, with `package-ecosystem: "docker-compose"`.
- A container auto-updater on your host pulls new builds of the tags you run and recreates the containers. It works without a Git repository, and you see changes only after they are live.

This Renovate config, saved as `renovate.json` in the repository that holds your compose files, adds and updates a digest on every image line:

<!-- include: examples/images/renovate.json -->

```json
{
  "$schema": "https://docs.renovatebot.com/renovate-schema.json",
  "extends": ["config:recommended"],
  "packageRules": [
    {
      "matchManagers": ["docker-compose"],
      "pinDigests": true
    }
  ]
}
```

<!-- /include -->

With `vX` plus a digest, Renovate proposes a new digest for each rebuild and release within that major version. It opens a separate pull request when a new major version comes out.

## Checking a signature

Every image is signed by the release workflow that built it, with [Sigstore cosign](https://docs.sigstore.dev/cosign/verifying/verify/). The signature proves that the image came from the cplieger release workflow, built for the app you asked for. Install cosign version 3 or later and Docker, then run these lines in a shell. Change `knell` to the app you run.

<!-- include: examples/images/verify.sh#setup -->

```sh
app="${1:-knell}"
tag="${2:-latest}"
image="ghcr.io/cplieger/${app}:${tag}"
```

<!-- /include -->

Then run the two lines from [Pinning a digest](#pinning-a-digest). The checks below read `$pinned`, so they all check the same build even if the tag moves while you work.

<!-- include: examples/images/verify.sh#cosign-verify -->

```sh
cosign verify \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-identity-regexp '^https://github\.com/cplieger/ci/\.github/workflows/docker-release\.yaml@' \
  --certificate-github-workflow-repository "cplieger/${app}" \
  "$pinned" >/dev/null
```

<!-- /include -->

When the signature is valid, cosign prints `Verification for ghcr.io/cplieger/knell@sha256:...` and the list of checks it performed, and exits 0. Without `>/dev/null`, it also prints the signature's details as JSON. Each flag checks one fact:

- `--certificate-oidc-issuer` requires that the signature was made inside GitHub Actions.
- `--certificate-identity-regexp` requires that the signing workflow is `docker-release.yaml` in the `cplieger/ci` repository, which builds every cplieger image.
- `--certificate-github-workflow-repository` requires that it ran for the app's own repository. Because every image shares one signing workflow, this flag is what ties a signature to one app. Without it, a signature from another cplieger app would pass.

To check a Docker Hub image, start `image` and `pinned` with `docker.io/cplieger/` instead. The cosign commands on this page then work the same way, with no Docker Hub account. If an old Docker Hub login is stored on your machine, cosign may fail with `401 incorrect username or password`. Run `docker logout` and try again.

## Reading the software bill of materials

Each image carries a signed software bill of materials, a list of every package inside it in the SPDX format. This command checks its signature with the same flags and prints how many packages it lists:

<!-- include: examples/images/verify.sh#cosign-attestation -->

```sh
cosign verify-attestation --type spdxjson \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-identity-regexp '^https://github\.com/cplieger/ci/\.github/workflows/docker-release\.yaml@' \
  --certificate-github-workflow-repository "cplieger/${app}" \
  "$pinned" | jq -rs '.[0].payload' | base64 -d | jq '.predicate.packages | length'
```

<!-- /include -->

It needs `jq`. Remove the last `jq` to see the whole list. Each image also carries the build provenance Docker records, which this page does not cover.

## Checking with the GitHub CLI

The [GitHub CLI](https://cli.github.com/manual/gh_attestation_verify) can check the same signed bill of materials. It needs a logged-in `gh`, so run `gh auth login` first. The next section needs it too.

<!-- include: examples/images/verify.sh#gh-attestation -->

```sh
gh attestation verify "oci://${pinned}" \
  --repo "cplieger/${app}" \
  --bundle-from-oci \
  --predicate-type https://spdx.dev/Document \
  --signer-workflow cplieger/ci/.github/workflows/docker-release.yaml
```

<!-- /include -->

When the check passes, `gh` prints `✓ Verification succeeded!` and the attestation it matched, and exits 0. In a script, where its output is not a terminal, it prints nothing and exits 0. The cplieger attestations are stored in the registry next to the image, so `--bundle-from-oci` is required. Without `--predicate-type`, `gh` looks for a build provenance attestation, which these images do not publish this way, and fails with `no attestations found`.

## The bill of materials attached to a release

Each release on the app's GitHub page also attaches a bill of materials as `sbom.spdx.json`, with its signature in `sbom.spdx.json.sigstore.json`. That file describes the build the release published. A tag such as `latest` or `v2.2.1` can later point to a rebuild from a newer commit, which the file does not describe.

So first read which commit your image was built from. The signature records it, and this command prints it:

<!-- include: examples/images/verify.sh#source-commit -->

```sh
commit="$(gh attestation verify "oci://${pinned}" \
  --repo "cplieger/${app}" \
  --bundle-from-oci \
  --predicate-type https://spdx.dev/Document \
  --signer-workflow cplieger/ci/.github/workflows/docker-release.yaml \
  --format json --jq '.[0].verificationResult.signature.certificate.sourceRepositoryDigest')"
```

<!-- /include -->

These lines then look for the release made from that commit. If there is one, they download its file and check that its signature was made for that same commit. A file restored to a release after it was published carries the signature of the later run that restored it, so for such a file they check instead that it is exactly the list signed into the image:

<!-- include: examples/images/verify.sh#release-sbom -->

```sh
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
  if verified="$(cosign verify-blob \
    --bundle "$dir/sbom.spdx.json.sigstore.json" \
    --certificate-oidc-issuer https://token.actions.githubusercontent.com \
    --certificate-identity-regexp '^https://github\.com/cplieger/ci/\.github/workflows/docker-release\.yaml@' \
    --certificate-github-workflow-repository "cplieger/${app}" \
    --certificate-github-workflow-sha "$commit" \
    "$dir/sbom.spdx.json" 2>&1)"; then
    echo "$verified"
  else
    # A file restored to the release later is signed by the run that restored it,
    # so it must instead be exactly the list signed into the image.
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
      "$pinned" | jq -rs '.[0].payload' | base64 -d | jq -S '.predicate' >"$dir/attested.json"
    if ! jq -S . "$dir/sbom.spdx.json" | cmp -s - "$dir/attested.json"; then
      echo "The file of $release is not the list signed into this image." >&2
      exit 1
    fi
    echo "The file of $release was restored later, and it is the list signed into this image."
  fi
fi
```

<!-- /include -->

cosign prints `Verified OK` when the file matches its signature. For a restored file, the lines then print that it is the list signed into the image. If no release was built from your image's commit, rely on the signed list in the image, from [Reading the software bill of materials](#reading-the-software-bill-of-materials). To check the image a release published, run the lines with the tag `sha-<commit>`, using the commit the release was made from.

## Checking all of it at once

`verify.sh` runs every command on this page for one image. Run `bash verify.sh <app> [tag]`, for example `bash verify.sh knell v2`.

<!-- include: examples/images/verify.sh -->

```sh
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
  if verified="$(cosign verify-blob \
    --bundle "$dir/sbom.spdx.json.sigstore.json" \
    --certificate-oidc-issuer https://token.actions.githubusercontent.com \
    --certificate-identity-regexp '^https://github\.com/cplieger/ci/\.github/workflows/docker-release\.yaml@' \
    --certificate-github-workflow-repository "cplieger/${app}" \
    --certificate-github-workflow-sha "$commit" \
    "$dir/sbom.spdx.json" 2>&1)"; then
    echo "$verified"
  else
    # A file restored to the release later is signed by the run that restored it,
    # so it must instead be exactly the list signed into the image.
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
      "$pinned" | jq -rs '.[0].payload' | base64 -d | jq -S '.predicate' >"$dir/attested.json"
    if ! jq -S . "$dir/sbom.spdx.json" | cmp -s - "$dir/attested.json"; then
      echo "The file of $release is not the list signed into this image." >&2
      exit 1
    fi
    echo "The file of $release was restored later, and it is the list signed into this image."
  fi
fi
# endregion: release-sbom
```

<!-- /include -->
