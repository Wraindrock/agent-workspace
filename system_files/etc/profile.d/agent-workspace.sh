# shellcheck shell=sh
# agent-workspace shell integration.
# Keep this file side-effect free apart from PATH and a couple of variables.

if [ -n "${HOME:-}" ]; then
  case ":${PATH}:" in
    *":${HOME}/.local/bin:"*) ;;
    *) PATH="${HOME}/.local/bin:${PATH}" ;;
  esac
  export PATH
fi

export AGENT_WORKSPACE_ROOT="${AGENT_WORKSPACE_ROOT:-/var/lib/agent-workspace}"
export AGENT_WORKSPACE_MANIFEST="${AGENT_WORKSPACE_MANIFEST:-/usr/share/agent-workspace/manifest.json}"

if [ -n "${BASH_VERSION:-}" ] && [ -r /usr/share/agent-workspace/modules.txt ]; then
  alias agent-modules='cat /usr/share/agent-workspace/modules.txt'
fi
