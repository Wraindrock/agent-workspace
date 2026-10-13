# Agents

Agents are installed by module `40-agent-harnesses`, which is a thin loop over
per-agent recipes. The selection is declarative:

~~~bash
# config/agents.conf - the default image
dsh=1
opencode=1

# recipes that exist but are not baked in
claude-code=0
codex=0
gemini-cli=0
aider=0
~~~

`=1` installs, `=0` skips, and anything unlisted is skipped. A single build can
override the file with `--build-arg AGENTS=dsh,opencode,codex`; `AGENTS=all`
follows the file.

## A recipe

`build_files/modules/40-agent-harnesses/agents/<name>.sh` declares three values
and one function:

~~~bash
#!/usr/bin/env bash
# Sourced by 40-agent-harnesses/install.sh; must define install_agent().
# shellcheck shell=bash
# my-agent - one line about what it is

# The command(s) this recipe installs, recorded in the image manifest.
AGENT_BINARIES="my-agent"
# Shown in the host installer's menu.
AGENT_TITLE="My Agent"
# The credential the CLI reads; the installer prompts for it.
AGENT_ENV="MY_AGENT_API_KEY"

install_agent() {
  npm_install_global my-agent-cli
}
~~~

The harness sources the recipe and calls `install_agent()`. Everything from
`build_files/lib/common.sh` is available, so recipes stay two or three lines in
the common case.

`AGENT_BINARIES` is the command the recipe puts on `PATH`. Recipe names and
commands do not always match - `claude-code` installs `claude`, `gemini-cli`
installs `gemini` - so the build records the mapping in `manifest.json`
(`agentBinaries`) and `agent-workspace agents` / `agent-workspace doctor`
check the real binary instead of guessing from the name. Space-separate several
commands if a recipe ships more than one.

The build also publishes `agentCatalog`: one entry per installed agent with its
binaries, its title and its credential variable. The host installer
(`install.sh`) reads that to build its menu, so the menu can only offer agents
the image really contains.

### Recipes that install from elsewhere

~~~bash
install_agent() {
  pipx_install aider-chat          # Python tools
}

install_agent() {
  retry 3 curl -fsSL https://example.com/install.sh -o /tmp/i.sh
  bash /tmp/i.sh
}
~~~

Rules of thumb:

- Pin a version when the upstream project breaks interfaces often:
  `npm_install_global "@openai/codex@0.9.1"`.
- Prefer `install_optional_rpms` over `install_rpms` for nice-to-have packages,
  so a Fedora rename cannot break the whole build.
- Never write long-lived state; the image is the durable artifact.

## Bundled recipes

| Agent | Recipe | Command | Credential (`AGENT_ENV`) | Installed via | In the default image |
| --- | --- | --- | --- | --- | --- |
| DSH (DeepSeek Harness) | `dsh.sh` | `dsh` | `DEEPSEEK_API_KEY` | npm `@deepseek-ai/dsh` | yes |
| OpenCode | `opencode.sh` | `opencode` | `DEEPSEEK_API_KEY` | npm `opencode-ai` | yes |
| Claude Code | `claude-code.sh` | `claude` | `ANTHROPIC_API_KEY` | npm `@anthropic-ai/claude-code` | no |
| Codex CLI | `codex.sh` | `codex` | `OPENAI_API_KEY` | npm `@openai/codex` | no |
| Gemini CLI | `gemini-cli.sh` | `gemini` | `GEMINI_API_KEY` | npm `@google/gemini-cli` | no |
| Aider | `aider.sh` | `aider` | `OPENAI_API_KEY` | pipx `aider-chat` | no |

`agent-workspace agents` lists what the running image actually has, cross-checked
against the manifest:

~~~text
  ok dsh -> /usr/bin/dsh
  ok opencode -> /usr/bin/opencode
  warn codex is declared in the manifest but its binary is missing
~~~

## Credentials

**No agent credentials are baked into the image, ever.** The image ships the CLIs;
each operator supplies their own keys. The idiomatic places are:

| Mechanism | Example |
| --- | --- |
| `/etc/agent-workspace/config.env` | per-instance overrides; the in-image CLI reads it at runtime |
| systemd credentials | `LoadCredential=` in a unit |
| podman secrets | `podman run --secret` for containerised agents |
| per-container env file | `install.sh` writes `~/.config/agent-workspace/containers/<name>.env` (mode 600) and passes it with `--env-file` |
| the agent's own login flow | `dsh`, `claude`, `codex login`, `gh auth login` |

Because the image is public and reproducible, treat every value in
`config/agents.conf` as "installable by anyone" and every secret as
"belongs to the operator".

## Adding an agent

1. Add `agents/<name>.sh` with `AGENT_BINARIES`, `AGENT_TITLE`,
   `AGENT_ENV` and `install_agent()`.
2. Add `<name>=1` to `config/agents.conf`.
3. `just check` validates that every name in `config/agents.conf` has a
   recipe, and that the recipe defines `install_agent()` and declares
   `AGENT_BINARIES`, `AGENT_TITLE` and `AGENT_ENV`.
4. Rebuild with `just verify` - the smoke test walks `agentCatalog` and checks
   every declared binary exists in the image.
