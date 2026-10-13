# Agents

Agents are installed by module `40-agent-harnesses`, which is a thin loop over
per-agent recipes. The selection is declarative:

~~~bash
# config/agents.conf
claude-code=1
codex=1
gemini-cli=1
opencode=0
aider=0
```

`=1` installs, `=0` skips, and anything unlisted is skipped. A single build can
override the file with `--build-arg AGENTS=codex,aider`.

## A recipe

`build_files/modules/40-agent-harnesses/agents/<name>.sh` defines one function:

~~~bash
#!/usr/bin/env bash
# my-agent - one line about what it is
AGENT_DESCRIPTION="My agent CLI"

install_agent() {
  npm_install_global my-agent-cli
}
```

The harness sources the recipe and calls `install_agent()`. Everything from
`build_files/lib/common.sh` is available, so recipes stay two or three lines in
the common case.

### Recipes that install from elsewhere

~~~bash
install_agent() {
  pipx_install aider-chat          # Python tools
}

install_agent() {
  retry 3 curl -fsSL https://example.com/install.sh -o /tmp/i.sh
  bash /tmp/i.sh
}
```

Rules of thumb:

- Pin a version when the upstream project breaks interfaces often:
  `npm_install_global "@openai/codex@0.9.1"`.
- Prefer `install_optional_rpms` over `install_rpms` for nice-to-have packages,
  so a Fedora rename cannot break the whole build.
- Never write long-lived state; the image is the durable artifact.

## Bundled recipes

| Agent | Recipe | Command | Installed via |
| --- | --- | --- | --- |
| Claude Code | `claude-code.sh` | `claude` | npm `@anthropic-ai/claude-code` |
| Codex CLI | `codex.sh` | `codex` | npm `@openai/codex` |
| Gemini CLI | `gemini-cli.sh` | `gemini` | npm `@google/gemini-cli` |
| OpenCode | `opencode.sh` | `opencode` | npm `opencode-ai` |
| Aider | `aider.sh` | `aider` | pipx `aider-chat` |

`agent-workspace agents` lists what the running image actually has, cross-checked
against the manifest:

~~~text
  ok claude-code -> /usr/bin/claude
  ok codex -> /usr/bin/codex
  warn gemini-cli is declared in the manifest but its binary is missing
```

## Credentials

**No agent credentials are baked into the image, ever.** The image ships the CLIs;
each operator supplies their own keys. The idiomatic places are:

| Mechanism | Example |
| --- | --- |
| `/etc/agent-workspace/config.env` | machine-level defaults, three-way merged by bootc |
| systemd credentials | `LoadCredential=` in a unit |
| podman secrets | `podman run --secret` for containerised agents |
| the agent's own login flow | `claude`, `codex login`, `gh auth login` |

Because the image is public and reproducible, treat every value in
`config/agents.conf` as "installable by anyone" and every secret as
"belongs to the operator".

## Adding an agent

1. Add `agents/<name>.sh` with `AGENT_DESCRIPTION` and `install_agent()`.
2. Add `<name>=1` to `config/agents.conf`.
3. `just check` validates that every name in `config/agents.conf` has a recipe.
4. Rebuild with `just verify` - the smoke test checks the binary exists.
