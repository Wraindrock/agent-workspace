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
bib_image := env_var("BIB_IMAGE")
agent_user := env_var("AGENT_USER")

alias build-vm := build-qcow2
alias rebuild-vm := rebuild-qcow2
alias run-vm := run-vm-qcow2

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
# Build the bootc image locally
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

# Boot the built image as a plain container and run the self test
[group('Build')]
smoke $target_image=image_name $tag=default_tag:
    bash tests/smoke.sh "${target_image}:${tag}"

# Rebuild the image and re-run the container self test
[group('Build')]
verify $target_image=image_name $tag=default_tag: (build target_image tag) && (smoke target_image tag)

# ---------------------------------------------------------------------------
# Sandbox - run a whole OS in a container to isolate an agent run
# ---------------------------------------------------------------------------
# Run the image as a disposable agent sandbox, $PWD mounted at /workspace.
#   just sandbox                 -> dsh
#   just sandbox opencode        -> the other bundled harness
#   just sandbox /bin/bash       -> just a shell inside the sandbox
[group('Sandbox')]
sandbox agent="dsh" dir="." $target_image=image_name $tag=default_tag:
    #!/usr/bin/env bash
    set -euo pipefail

    # rootless podman maps the container's root to the calling user, so
    # everything the agent writes into /workspace stays owned by you.
    exec podman run --rm -it \
      --hostname agent-sandbox \
      --volume "${dir}:/workspace:z" \
      --workdir /workspace \
      "${target_image}:${tag}" "${agent}"

# Create agent containers on this host with the interactive installer.
# Flags reach install.sh after --, e.g. "just install -- --list".
[group('Sandbox')]
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
# Declarative lifecycle - runs on the deployed host, not in CI
# ---------------------------------------------------------------------------
# Print bootc deployment status (booted / staged / rolled back)
[group('Lifecycle')]
status:
    sudo bash scripts/switch.sh --status

# Move this machine to another published tag of agent-workspace
[group('Lifecycle')]
switch tag=default_tag:
    sudo bash scripts/switch.sh "${tag}"

# Revert to the previously booted deployment (transactional, offline)
[group('Lifecycle')]
rollback:
    sudo bash scripts/rollback.sh

# Verify the running system matches the image it claims to be
[group('Lifecycle')]
doctor:
    bash scripts/doctor.sh

# ---------------------------------------------------------------------------
# Disk images (bootc-image-builder)
# ---------------------------------------------------------------------------
# Build a bootable qcow2 from the published image
[group('Disk images')]
build-qcow2 $target_image=image_name $tag=default_tag:
    #!/usr/bin/env bash
    set -euo pipefail
    sudo podman run --rm -it --privileged --pull=newer \
      --security-opt label=type:unconfined_t \
      --volume "$PWD/output:/output" \
      --volume /var/lib/containers/storage:/var/lib/containers/storage \
      --volume "$PWD/disk_config/disk.toml:/config.toml:ro" \
      "${bib_image}" \
      --type qcow2 --use-librepo=True --rootfs btrfs \
      "ghcr.io/${repo_organization,,}/${image_name}:${tag}"

# Build an installable ISO from the published image
[group('Disk images')]
build-iso $target_image=image_name $tag=default_tag:
    #!/usr/bin/env bash
    set -euo pipefail
    sudo podman run --rm -it --privileged --pull=newer \
      --security-opt label=type:unconfined_t \
      --volume "$PWD/output:/output" \
      --volume /var/lib/containers/storage:/var/lib/containers/storage \
      --volume "$PWD/disk_config/iso.toml:/config.toml:ro" \
      --volume "$PWD/disk_config/disk.toml:/disk.toml:ro" \
      "${bib_image}" \
      --type anaconda-iso --use-librepo=True --rootfs btrfs \
      "ghcr.io/${repo_organization,,}/${image_name}:${tag}"

# Rebuild the qcow2 from scratch (cleans output/ first)
[group('Disk images')]
rebuild-qcow2: clean (build-qcow2)

# Rebuild the ISO from scratch (cleans output/ first)
[group('Disk images')]
rebuild-iso: clean (build-iso)

# Run the qcow2 produced by build-qcow2 in a throwaway VM
[group('Disk images')]
run-vm-qcow2 ram="6G":
    #!/usr/bin/env bash
    set -euo pipefail
    disk="$(find output -name '*.qcow2' | head -n1)"
    [[ -n "${disk}" ]] || { echo "no qcow2 in output/, run 'just build-qcow2' first" >&2; exit 1; }
    qemu-system-x86_64 -enable-kvm -m "${ram}" -cpu host -smp 4 \
      -drive "file=${disk},if=virtio,format=qcow2" \
      -device virtio-vga -netdev user,id=net0,hostfwd=tcp::2222-:22 -device virtio-net-pci,netdev=net0

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
    rm -rf output output.env _build* *_chunkah_* *_rpm-ostree_*
    echo "cleaned"
