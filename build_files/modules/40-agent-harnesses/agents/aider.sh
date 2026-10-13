#!/usr/bin/env bash
# Sourced by 40-agent-harnesses/install.sh; must define install_agent().
# shellcheck shell=bash
# Aider - Python pair-programming agent.
# The command(s) this recipe installs, recorded in the image manifest so
# runner-facing checks look for the real binary instead of guessing it.
# shellcheck disable=SC2034 # consumed by the harness that sources this recipe
AGENT_BINARIES="aider"

install_agent() {
  pipx_install aider-chat
  aider --version 2>/dev/null | head -n1 | while read -r v; do record_value tool "aider $v"; done
}
