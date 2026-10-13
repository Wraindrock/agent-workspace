#!/usr/bin/env bash
# Sourced by 40-agent-harnesses/install.sh; must define install_agent().
# shellcheck shell=bash
# Aider - Python pair-programming agent.
install_agent() {
  pipx_install aider-chat
  aider --version 2>/dev/null | head -n1 | while read -r v; do record_value tool "aider $v"; done
}
