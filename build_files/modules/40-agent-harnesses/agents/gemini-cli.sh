#!/usr/bin/env bash
# Sourced by 40-agent-harnesses/install.sh; must define install_agent().
# shellcheck shell=bash
# Google Gemini CLI - terminal coding agent.
install_agent() {
  npm_install_global @google/gemini-cli
  gemini --version 2>/dev/null | head -n1 | while read -r v; do record_value tool "gemini-cli $v"; done
}
