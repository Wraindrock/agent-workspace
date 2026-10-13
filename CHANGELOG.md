# Changelog

All notable changes to this project are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html)
for the *declarative surface* - `config/*.conf`, `image.env`, and the
`agent-workspace` CLI. Day-to-day image builds are identified by tag
(`YYYYMMDD`, `YYYYMMDD-<sha>`) rather than by version number.

## [Unreleased]

## [0.1.0] - 2026-10-13

The first structure release: a complete, buildable, publishable skeleton.

### Added

- `Containerfile` with a `ctx` build stage, OCI/Artifact Hub labels, a single
  pipeline `RUN`, and `bootc container lint` as the final gate.
- The module pipeline: `build_files/build.sh` plus `build_files/lib/common.sh`,
  with three-level enable resolution (`IMAGE_MODULES` build argument,
  `config/modules.conf`, `MODULE_ENABLED_DEFAULT`).
- Nine modules: `00-preflight`, `10-base-packages`, `20-container-tools`,
  `30-agent-toolchains`, `40-agent-harnesses`, `50-devtools`,
  `60-system-config`, `80-manifest`, `90-cleanup`.
- Agent recipes for Claude Code, Codex CLI, Gemini CLI, OpenCode and Aider,
  selected through `config/agents.conf`.
- The in-image `agent-workspace` CLI: `version`, `manifest`, `modules`,
  `agents`, `status`, `doctor`, `switch`, `rollback`, `update`, `pin`.
- First-boot provisioning (`agent-workspace-firstboot.service`) that creates the
  unprivileged agent user with a sub-id range and enables lingering.
- A daily `agent-workspace-health.timer` running `doctor --quiet`.
- A machine-readable build manifest at `/usr/share/agent-workspace/manifest.json`
  and its shell-accessible counterpart `/etc/agent-workspace/build.env`.
- Host-side helpers: `scripts/switch.sh`, `scripts/rollback.sh`,
  `scripts/doctor.sh`, `scripts/cosign-keygen.sh`.
- CI: `build.yml` (lint, build, container self test, push, cosign signing with
  keyless OIDC by default) and `build-disk.yml` (qcow2/raw/ISO via
  bootc-image-builder).
- `tests/lint.sh` and `tests/smoke.sh`, run both locally through the Justfile
  and in CI.
- Documentation: `README.md`, `README.zh-CN.md`, `docs/architecture.md`,
  `docs/modules.md`, `docs/agents.md`, `docs/rollback.md`.
- Project files: MIT `LICENSE`, `CONTRIBUTING.md`, `SECURITY.md`,
  `CODE_OF_CONDUCT.md`, issue and pull request templates, Dependabot and
  Renovate configuration.

[Unreleased]: https://github.com/wraindrock/agent-workspace/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/wraindrock/agent-workspace/releases/tag/v0.1.0
