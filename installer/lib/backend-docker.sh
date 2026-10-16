#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# docker backend.
#
# docker needs more help booting systemd than podman does: the cgroup namespace
# and the cgroup mounts have to come from the flags, and that in turn is why
# this backend runs the workspace privileged. The installer says so in
# SECURITY.md, and `--backend podman` (or Incus) avoids it.
# ---------------------------------------------------------------------------

# shellcheck source=installer/lib/backend-container-cli.sh
source "${BACKEND_DIR}/backend-container-cli.sh"

eng_run_flags() {
  printf '%s\n' --detach --restart unless-stopped --privileged --cgroupns=host
  printf '%s\n' --volume /sys/fs/cgroup:/sys/fs/cgroup:rw
  printf '%s\n' --tmpfs /run --tmpfs /tmp
}

# docker's commit has no --format flag, so it picks its own default.
eng_commit() {
  run_engine commit "$1" "$2"
}
