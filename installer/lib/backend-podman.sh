#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# podman backend.
#
# podman runs the image as a complete Linux system: systemd is PID 1 and the
# agent is reached with "exec". It needs no privileges beyond the user's own,
# which is why it stays the fallback for hosts without an Incus daemon.
# ---------------------------------------------------------------------------

# shellcheck source=installer/lib/backend-container-cli.sh
source "${BACKEND_DIR}/backend-container-cli.sh"

# Mount the workspace with the relabel suffix: SELinux hosts need it, and the
# container CLIs accept it everywhere.
eng_run_flags() {
  printf '%s\n' --detach --systemd=always --restart unless-stopped
}

# podman can pin the image format, so a snapshot is a reproducible OCI image.
eng_commit() {
  run_engine commit --format oci "$1" "$2"
}
