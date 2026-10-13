#!/usr/bin/env bash
# Sourced by 40-agent-harnesses/install.sh; must define install_agent().
# shellcheck shell=bash
# OpenAI Codex CLI - terminal coding agent.
install_agent() {
  npm_install_global @openai/codex
  codex --version 2>/dev/null | head -n1 | while read -r v; do record_value tool "codex $v"; done
}
