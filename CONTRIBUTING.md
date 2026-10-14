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
gracefully: `shellcheck`, `actionlint`, `just` and `pyyaml` are used when
present, skipped when not. Documentation counts as part of a change: the lint
fails when any file in its fixed required list is missing, and it checks that
`config/modules.conf` and `config/agents.conf` only reference real modules and
recipes. Keep the module and agent tables in `README.md` and `docs/` matching the
code. `tests/install.sh` drives `install.sh` against the fake container engine in
`tests/fixtures/fake-engine.sh`, so the host installer is covered in CI without
podman, docker or root. The build workflow installs the pinned `actionlint`
and `just`, so a workflow edit that uses an unavailable context - or a Justfile
that no longer parses - fails in CI before any build.

## Adding a module

1. `build_files/modules/<NN-name>/` with `module.env` and `install.sh`.
2. `MODULE_NAME` must equal the directory name, `module.env` must be sourceable
   by bash, and `install.sh` must be executable and do its work at the top level
   (nothing sources it).
3. Pin the repository-wide decision in `config/modules.conf`.
4. Document it in the module table in `README.md` and `docs/modules.md`.

## Adding an agent

1. `build_files/modules/40-agent-harnesses/agents/<name>.sh` declaring
   `AGENT_BINARIES` (the commands it installs), `AGENT_TITLE` (the label shown in
   the installer menu), `AGENT_ENV` (the credential variable it needs) and
   `install_agent()`.
2. Add `<name>=1` (or `=0`) to `config/agents.conf`.
3. `just check` verifies the reference resolves and that the recipe declares all
   three fields; the smoke test verifies every binary listed in the image's
   `agentCatalog` exists in the built image.

## Changing the image identity

`image.env` is the single source of truth for name, organisation, description,
default tag and base image. The Justfile and `.github/workflows/build.yml` read
it; the Containerfile only declares the matching build arguments. If you need a
new parameter there, plumb it through the Justfile, the workflow and the
Containerfile ARGs.

## Third-party patches

This image is built from upstream components - base packages, npm packages, agent
CLIs - and any of them can change under us. When we need behaviour upstream does not
have yet, stay honest about it:

- **Configuration before patches.** Anything the upstream tool accepts as a config
  file, an environment variable or a flag belongs in `system_files/`, `config/` or
  the installer - not in a patch.
- **Pin first, then patch.** Pin the version (`config/*.conf`, `image.env`) and keep
  the patch in a build module. A patch script must assert that the exact text it
  replaces is present exactly once, and fail the build when it is not, so an upstream
  release breaks the build instead of silently shipping a half-patched image.
- **Never rewrite an installed tool at runtime.** First boot may *seed* a user's
  configuration idempotently; it must not modify the tool that reads it.
- **Write down why.** Every patch carries a comment naming the upstream issue or
  behaviour it works around, and the module table in `docs/modules.md` mentions it.
  When upstream fixes it, delete the patch in the same change that bumps the pin.
- **Prefer upstream.** A patch that survives more than a release or two should be a
  pull request against the upstream project, not a permanent local fork.

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

Commits are authored as `Wraindrock <Wraindrock@users.noreply.github.com>`, which
is what this repository's local git config sets. A few early commits carry the
same account under a lower-case address (`<wraindrock@...>`), so `.mailmap` folds
that spelling into the canonical identity. The other early author,
`Ian <ian@users.noreply.github.com>`, is a different person and is deliberately
left as himself: folding him in would hide his commits from
`git log --author=ian`. History is *not* rewritten for either of them, because
the published image tags embed commit hashes and a rewrite would orphan every
one of them.

## Reporting bugs and security issues

Bugs: open an [issue](https://github.com/wraindrock/agent-workspace/issues/new/choose)
with `agent-workspace version` output and the command that failed.

Security: do **not** open a public issue - see [SECURITY.md](SECURITY.md).
