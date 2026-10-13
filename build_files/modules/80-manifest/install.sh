#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../../lib/common.sh
source "${COMMON_LIB:?COMMON_LIB must point at build_files/lib/common.sh}"

require_command jq

manifest_dir=/usr/share/agent-workspace
manifest="${manifest_dir}/manifest.json"
mkdir -p "$manifest_dir"

modules_json="$(jq -R -s 'split("\n") | map(select(length > 0))' "${STATE_DIR}/modules.enabled")"
agents_json="$(jq -R -s 'split("\n") | map(select(length > 0))' "${STATE_DIR}/agents.enabled")"
tools_json="$(jq -R -s 'split("\n") | map(select(length > 0))' "${STATE_DIR}/tool" 2>/dev/null || echo '[]')"

version_of() {
  local binary="$1"
  command -v "$binary" >/dev/null 2>&1 && "$binary" --version 2>/dev/null | head -n1 || echo "not installed"
}

fedora_release="$(. /etc/os-release 2>/dev/null; echo "${VERSION_ID:-unknown}")"
image_name="${AGENT_WORKSPACE_IMAGE:-unknown}"

jq -n \
  --arg schema "1" \
  --arg image "$image_name" \
  --arg version "${AGENT_WORKSPACE_VERSION:-unknown}" \
  --arg base_image "${AGENT_WORKSPACE_BASE_IMAGE:-unknown}" \
  --arg fedora "$fedora_release" \
  --arg git_sha "${AGENT_WORKSPACE_GIT_SHA:-unknown}" \
  --arg build_date "${AGENT_WORKSPACE_BUILD_DATE:-unknown}" \
  --arg agent_user "${AGENT_WORKSPACE_USER:-agent}" \
  --arg license "MIT" \
  --arg bootc "$(version_of bootc)" \
  --arg podman "$(version_of podman)" \
  --arg node "$(version_of node)" \
  --arg python "$(version_of python3)" \
  --arg git "$(version_of git)" \
  --argjson modules "$modules_json" \
  --argjson agents "$agents_json" \
  --argjson extra_tools "$tools_json" \
  '{
    schemaVersion: ($schema | tonumber),
    image: $image,
    version: $version,
    baseImage: $base_image,
    fedoraRelease: $fedora,
    gitSha: $git_sha,
    buildDate: $build_date,
    agentUser: $agent_user,
    license: $license,
    modules: $modules,
    agents: $agents,
    toolchain: {
      bootc: $bootc,
      podman: $podman,
      node: $node,
      python: $python,
      git: $git
    },
    extraTools: $extra_tools
  }' > "$manifest"

cp "${STATE_DIR}/modules.enabled" "${manifest_dir}/modules.txt"
install -d -m 0755 /etc/agent-workspace
install -m 0644 "$manifest" /etc/agent-workspace/manifest.json

jq -e . "$manifest" >/dev/null || die "generated manifest is not valid JSON"
ok "manifest written to $manifest"
