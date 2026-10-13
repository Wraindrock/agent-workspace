# Contributing

Thanks for helping. This project is small on purpose: a declarative build, a
handful of modules, and a CLI that has to be honest about what the image
contains. Contributions that keep it that way are the easiest to merge.

## Ground rules

- **Declaration over procedure.** If something must be true for every machine,
  add it to a module or a config file. First-boot scripts and runtime mutation
  are a last resort.
- **Everything is switchable.** A new module needs a sane
  `MODULE_ENABLED_DEFAULT` and an entry in `config/modules.conf`.
- **One licence.** The repository is MIT. Do not copy files from projects under
  other licences; reimplement from their documented behaviour instead.
- **No secrets, ever.** Not in modules, not in `config/`, not in tests.

## Getting set up

~~~bash
git clone https://github.com/wraindrock/agent-workspace
cd agent-workspace
just check      # fast: shell syntax, module contract, docs presence
just verify     # slow: builds the image and runs the container self test
~~~

If you do not have `just`, the tests are plain scripts:

~~~bash
bash tests/lint.sh          # includes tests/install.sh, which needs no container engine
bash tests/install.sh       # only the installer tests, against a fake podman
podman build -t localhost/agent-workspace:dev .
bash tests/smoke.sh localhost/agent-workspace:dev
~~~

`tests/lint.sh` is the same check CI runs on every pull request, and it degrades
gracefully: `shellcheck`, `actionlint`, `just`, `jq` and `pyyaml` are used when
present, skipped when not. `tests/install.sh` drives `install.sh` against a fake
`podman`, so the host installer is covered in CI without a container engine or
root. The build workflow installs the pinned `actionlint`
and `just`, so a workflow edit that uses an unavailable context - or a Justfile
that no longer parses - fails in CI before any build.

## Adding a module

1. `build_files/modules/<NN-name>/` with `module.env` and `install.sh`.
2. `MODULE_NAME` must equal the directory name, and `install.sh` must define
   `install_module()` with no other side effects at load time.
3. Pin the repository-wide decision in `config/modules.conf`.
4. Document it in the module table in `README.md` and `docs/modules.md`.

## Adding an agent

1. `build_files/modules/40-agent-harnesses/agents/<name>.sh` with
   `AGENT_BINARIES` (the command it installs) and `install_agent()`.
2. Add `<name>=1` (or `=0`) to `config/agents.conf`.
3. `just check` verifies the reference resolves and the recipe declares both;
   the smoke test verifies the declared binary exists in the built image.

## Changing the image identity

`image.env` is the single source of truth for name, organisation, description,
default tag and base image. The Justfile, the Containerfile and both workflows
read it. If you need a new parameter there, plumb it through all four.

## Pull requests

- Keep one concern per pull request; a module move plus a CI rewrite is two.
- Run `just check` before pushing - CI fails on the same lint.
- Fill in the pull request template, especially the *declarative surface* rows.
- Describe how you verified the change. "It builds" is fine for docs; image
  changes should include `just verify` output.

## Commit messages

```text
feat(modules): add a 55-gpu-tooling module
fix(cli): do not report a missing agent twice
docs(rollback): document the :previous tag
chore(ci): pin cosign-installer
```

Conventional-commit prefixes (`feat`, `fix`, `docs`, `chore`, `refactor`,
`test`) are used by the renovate config for grouping; keeping to them makes
dependency pull requests readable.

## Reporting bugs and security issues

Bugs: open an [issue](https://github.com/wraindrock/agent-workspace/issues/new/choose)
with `agent-workspace version` output and the command that failed.

Security: do **not** open a public issue - see [SECURITY.md](SECURITY.md).
