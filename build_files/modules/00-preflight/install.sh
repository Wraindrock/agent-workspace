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

# On ostree/bootc images /usr/local points at /var/usrlocal and /root points
# at /var/roothome. Neither target exists inside a build container, so
# anything writing to /usr/local/bin or to $HOME (npm --global, pipx, curl
# installers) dies with `ENOTDIR: not a directory, mkdir ...`. Materialise
# both targets before any other module runs.
for dir_mode in "/usr/local:0755" "/root:0700"; do
  dir="${dir_mode%%:*}"
  mode="${dir_mode##*:}"
  if [[ -L "${dir}" ]]; then
    target="$(readlink -f "${dir}" || true)"
    [[ -n "${target}" ]] || die "${dir} is a symlink whose target cannot be resolved"
    install -d -m "${mode}" "${target}"
    ok "prepared ${target} for the ${dir} symlink"
  else
    install -d -m "${mode}" "${dir}"
  fi
done
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
