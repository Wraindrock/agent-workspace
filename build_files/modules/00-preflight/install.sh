#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../../lib/common.sh
source "${COMMON_LIB:?COMMON_LIB must point at build_files/lib/common.sh}"

require_command bootc
require_command systemctl

# Directories the rest of the image (and the runtime CLI) rely on.
install -d -m 0755 /usr/share/agent-workspace
install -d -m 0755 /usr/lib/agent-workspace
install -d -m 0755 /etc/agent-workspace
install -d -m 0755 /var/lib/agent-workspace

# On ostree/bootc images /usr/local is a symlink to /var/usrlocal, and that
# target does not exist inside a build container. Anything that writes to
# /usr/local/bin (npm --global, pipx, curl installers) fails with ENOTDIR
# until the target exists, so materialise it before any module needs it.
if [[ -L /usr/local ]]; then
  usr_local_target="$(readlink -f /usr/local || true)"
  [[ -n "${usr_local_target}" ]] || die "/usr/local is a symlink whose target cannot be resolved"
  install -d -m 0755 "${usr_local_target}"
  ok "prepared ${usr_local_target} for the /usr/local symlink"
fi
install -d -m 0755 /usr/local/bin

fedora_release="unknown"
# shellcheck disable=SC1091
[[ -r /etc/os-release ]] && . /etc/os-release && fedora_release="${VERSION_ID:-unknown}"

{
  echo "# Generated at image build time. Edit here only if you know what you are doing;"
  echo "# configuration belongs in /etc/agent-workspace/config.env on the host."
  echo "AGENT_WORKSPACE_IMAGE=${AGENT_WORKSPACE_IMAGE:-unknown}"
  echo "AGENT_WORKSPACE_VERSION=${AGENT_WORKSPACE_VERSION:-unknown}"
  echo "AGENT_WORKSPACE_BASE_IMAGE=${AGENT_WORKSPACE_BASE_IMAGE:-unknown}"
  echo "AGENT_WORKSPACE_USER=${AGENT_WORKSPACE_USER:-agent}"
  echo "AGENT_WORKSPACE_FEDORA=${fedora_release}"
} > /etc/agent-workspace/build.env

record_value base_image "${AGENT_WORKSPACE_BASE_IMAGE:-unknown}"
record_value fedora_release "$fedora_release"
ok "base image: ${AGENT_WORKSPACE_BASE_IMAGE:-unknown} (Fedora ${fedora_release})"
