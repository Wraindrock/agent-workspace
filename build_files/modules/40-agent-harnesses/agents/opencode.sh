#!/usr/bin/env bash
# Sourced by 40-agent-harnesses/install.sh; must define install_agent().
# shellcheck shell=bash
# opencode - open-source terminal coding agent.
install_agent() {
  npm_install_global opencode-ai
  opencode --version 2>/dev/null | head -n1 | while read -r v; do record_value tool "opencode $v"; done
}
