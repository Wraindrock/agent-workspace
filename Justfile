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

# Re-stamp the bootstrap checksums inside install.sh after editing
# installer/lib/*.sh or image.env. `curl | bash` installs without a checkout, so
# install.sh carries the digests of the files it fetches; a stale stamp means the
# bootstrap would refuse the very files it was built from. `just check` fails
# when this is out of date, so run it as part of the same commit.
[group('Lint')]
stamp:
    bash scripts/stamp-install.sh

# Verify the stamp without rewriting it.
[group('Lint')]
stamp-check:
    bash scripts/stamp-install.sh --check

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

# Boot the built image through install.sh on the real engine. The self test
# overrides the image command, so only this proves the container the installer
# creates actually runs. It needs a host whose rootless podman can start systemd
# (if it fails with "Too many open files", see docs/containers.md).
[group('Build')]
integration $target_image=image_name $tag=default_tag:
    bash tests/integration.sh "${target_image}:${tag}"

# Assert the image boots on a host that was never tuned: PID 1 must be systemd,
# and the run records the host's inotify budget rather than demanding one. It
# does not drive install.sh, so it also works where the installer state
# directory is not writable.
[group('Build')]
portability $target_image=image_name $tag=default_tag:
    bash tests/portability.sh "${target_image}:${tag}"

# Behavioural half of the decoupling contract (the sysctl drop-in stays deleted,
# the assertions guarding it still have a failing branch). Text-level, so it
# needs no engine and no privileges and can run anywhere.
[group('Lint')]
decoupling:
    bash tests/decoupling.sh

# The declared compatibility surface (config/*.conf, image.env, install.sh and
# the agent-workspace CLI, the set CHANGELOG.md names). Static and CLI-level
# only, so it needs no image, no engine and no root: it runs on every pull
# request, including one made before the first release exists.
[group('Lint')]
contract:
    bash tests/contract.sh

# firstboot provisioning is idempotent and survives a uid the container's user
# namespace cannot name. The marker, the unit's guard and the uid_map column
# order are all text-level here, so like the other contracts it needs no engine.
[group('Lint')]
firstboot:
    bash tests/firstboot.sh

# The curl|bash install path: install.sh fetches its own libraries and verifies
# them against digests carried inside the script. Drives the real bootstrap_fetch
# (via its download seam, so no network) and asserts a mismatched file is
# refused rather than warned about. Engine-free and network-free.
[group('Lint')]
bootstrap:
    bash tests/bootstrap.sh

# Re-run every container-level test against an image that is already built,
# plus the engine-free decoupling assertions.
[group('Build')]
containers $target_image=image_name $tag=default_tag: (smoke target_image tag) && (portability target_image tag)
[group('Build')]
containers-all $target_image=image_name $tag=default_tag: (containers target_image tag) && (integration target_image tag)
[group('Build')]
containers-full $target_image=image_name $tag=default_tag: (containers-all target_image tag) && (decoupling)
# static: source-level only, no image required. The engine-free half of the
# suite: the text-level contract tests. Kept as its own name for the same
# one-`&&`-per-recipe reason as the others, and because it is the part that needs
# neither an image nor a usable engine - run this on a checkout before anything
# has been built.
[group('Lint')]
static: (decoupling) && (contract)
# The interface's language handling: locale detection, catalogue completeness, and
# the fact that the TUI dispatches on a stable key rather than on the translated
# label it happens to be showing.
[group('Lint')]
language:
    bash tests/i18n.sh
# The engine-free suite plus the firstboot and bootstrap contracts. `just` allows
# one `&&` chain per recipe, so the middle name carries the third dependency for
# the same reason `static` exists at all; `verify-all` is what runs everything.
[group('Lint')]
static-more: (firstboot) && (bootstrap)
# Carries the remaining engine-free checks; see `static-more` for why these names
# are split up.
[group('Lint')]
static-rest: (language) && (static-more)
# The engine-free suite plus the firstboot and bootstrap contracts.
[group('Lint')]
static-all: (static) && (static-rest)

# verify: requires a built image. Rebuilds it first, then re-runs every test that
# exercises it. Depends on `containers-full`, not `containers`: `just` allows only
# one `&&` chain per recipe, so the extra names exist to carry the further chains.
# The source-level tests are deliberately not here - they need no image, and
# folding them in would make a static check un-runnable until a build finished.
# `static` is that half; `verify-all` is the two together.
[group('Build')]
verify $target_image=image_name $tag=default_tag: (build target_image tag) && (containers-full target_image tag)
# Everything `verify` proves, plus the engine-free contract and decoupling
# assertions that need no image at all. This is the documented "runs
# everything" entry point; `verify` stops short of it only because the two
# remaining tests do not need the image it just built.
[group('Build')]
verify-all $target_image=image_name $tag=default_tag: (verify target_image tag) && (static-all)

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
