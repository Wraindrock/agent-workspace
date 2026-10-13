set dotenv-filename := "image.env"
set dotenv-load
set export

image_name := env_var("IMAGE_NAME")
repo_organization := env_var("REPO_ORGANIZATION")
image_desc := env_var("IMAGE_DESC")
image_keywords := env_var("IMAGE_KEYWORDS")
image_logo_url := env_var("IMAGE_LOGO_URL")
image_license := env_var("IMAGE_LICENSE")
default_tag := env_var("DEFAULT_TAG")
base_image := env_var("BASE_IMAGE")
agent_user := env_var("AGENT_USER")

# List recipes
default:
    @just --list

# ---------------------------------------------------------------------------
# Static checks - no podman required, runs on every pull request
# ---------------------------------------------------------------------------
[group('Lint')]
check:
    bash tests/lint.sh

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------
# Build the container image locally (podman build)
[group('Build')]
build $target_image=image_name $tag=default_tag:
    #!/usr/bin/env bash
    set -euo pipefail

    git_sha="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
    build_date="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    registry="ghcr.io/${repo_organization,,}"

    podman build \
      --pull=newer \
      --build-arg "BASE_IMAGE=${base_image}" \
      --build-arg "IMAGE_NAME=${image_name}" \
      --build-arg "IMAGE_REGISTRY=${registry}" \
      --build-arg "IMAGE_VERSION=${tag}" \
      --build-arg "GIT_SHA=${git_sha}" \
      --build-arg "BUILD_DATE=${build_date}" \
      --build-arg "AGENT_USER=${agent_user}" \
      --label "org.opencontainers.image.created=${build_date}" \
      --label "org.opencontainers.image.version=${tag}" \
      --label "org.opencontainers.image.revision=${git_sha}" \
      --label "org.opencontainers.image.description=${image_desc}" \
      --label "org.opencontainers.image.licenses=${image_license}" \
      --label "io.artifacthub.package.logo-url=${image_logo_url}" \
      --tag "${target_image}:${tag}" \
      --file Containerfile \
      .

# Boot the built image as a system container and run the self test
[group('Build')]
smoke $target_image=image_name $tag=default_tag:
    bash tests/smoke.sh "${target_image}:${tag}"

# Rebuild the image and re-run the container self test
[group('Build')]
verify $target_image=image_name $tag=default_tag: (build target_image tag) && (smoke target_image tag)

# ---------------------------------------------------------------------------
# Containers - the only way this project is used
# ---------------------------------------------------------------------------
# Create and manage agent containers on this host, in the installer's TUI
# Create with: just install -- --list (see docs/containers.md)
[group('Containers')]
install *args:
    ./install.sh {{args}}

# ---------------------------------------------------------------------------
# Release helpers - used by .github/workflows/build.yml
# ---------------------------------------------------------------------------
# Print the image name
[group('Release')]
[private]
image-name:
    @echo "${image_name}"

# Print the tag that represents this repository's moving target
[group('Release')]
generate-default-tag:
    @echo "${default_tag}"

# Print the immutable tags to publish for this build
[group('Release')]
generate-build-tags $target_image=image_name $tag=default_tag:
    #!/usr/bin/env bash
    set -euo pipefail

    date_tag="$(date -u +%Y%m%d)"
    tags=()

    if git rev-parse --short HEAD >/dev/null 2>&1; then
      git_sha="$(git rev-parse --short HEAD)"
      tags+=("${tag}-${git_sha}")
      tags+=("${date_tag}-${git_sha}")
    fi

    tags+=("${date_tag}")
    tags+=("${tag}")
    tags+=("${tag}-${date_tag}")

    echo "${tags[*]}"

# Apply alias tags to an already built local image
[group('Release')]
tag-images $target_image=image_name $tag=default_tag tags="":
    #!/usr/bin/env bash
    set -euo pipefail

    image_id="$(podman image inspect "${target_image}:${tag}" --format '{{{{.Id}}}}')"

    for alias in ${tags}; do
      podman tag "${image_id}" "${target_image}:${alias}"
    done

    podman images --filter "reference=${target_image}"

# Push a local image tag to the registry
[group('Release')]
push $target_image=image_name $tag=default_tag:
    #!/usr/bin/env bash
    set -euo pipefail
    registry="ghcr.io/${repo_organization,,}"
    podman push "${target_image}:${tag}" "${registry}/${image_name}:${tag}"

# ---------------------------------------------------------------------------
# Maintenance
# ---------------------------------------------------------------------------
# Generate a cosign key pair for key-based image signing
[group('Maintenance')]
cosign-keygen name="agent-workspace":
    bash scripts/cosign-keygen.sh "${name}"

# Remove build outputs and caches
[group('Maintenance')]
clean:
    #!/usr/bin/env bash
    set -euo pipefail
    rm -rf output output.env _build* *_chunkah_*
    echo "cleaned"
