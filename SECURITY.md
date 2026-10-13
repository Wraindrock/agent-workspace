# Security policy

## Reporting a vulnerability

Please do not open a public issue for a security problem.

Use GitHub's private reporting:
<https://github.com/wraindrock/agent-workspace/security/advisories/new>

Include, as far as you can:

- what is affected (the image tag, the CLI, a module, or CI),
- the exact reproduction steps,
- the impact you believe it has.

You will get an acknowledgement within **72 hours** and an assessment within
**7 days**. Fixes are released as a new image tag plus, where relevant, a
rotation of anything that leaked.

## What this project is responsible for

| In scope | Out of scope |
| --- | --- |
| The build pipeline and what the image ships | Vulnerabilities in Fedora packages (report upstream; we pick up fixes via the base image) |
| The `agent-workspace` CLI and its systemd units | The agent CLIs' own behaviour with your credentials |
| CI/CD: what can push to GHCR, what can sign | Your GHCR repository settings and personal access tokens |
| Secrets hygiene in the repository | Operator mistakes such as committing keys to a fork |

## Design decisions that affect security

- **No credentials in the image.** Agent API keys, tokens and SSH keys are never
  baked in; the smoke test and lint run without any secrets present.
- **Keyless signing by default.** Releases are signed with a short-lived
  certificate bound to the workflow identity, so there is no long-lived private
  key to steal. `cosign verify` with an identity regexp is the recommended
  verification path. Key-based signing (a `SIGNING_SECRET` repository secret) is
  supported for fleets that verify against a pinned public key.
- **The image is the only writable-by-no-one layer.** On a booted system, agent
  tooling runs as the unprivileged `agent` user with rootless podman and a
  sub-id range; the OS layers stay immutable.
- **`/etc` is deliberately mergeable.** Operator overrides survive updates,
  which also means a hostile override survives them. Treat write access to
  `/etc/agent-workspace/config.env` as privileged.
- **Unqualified container names are permissive.** The registries drop-in enables
  short names so agents can `podman run alpine` without ceremony; if your threat
  model dislikes that, turn it off in `system_files/etc/containers/registries.conf.d/00-agent-workspace.conf`.

## Supported versions

Only the newest published tag (and the newest dated tag) receives fixes. There
are no long-term support branches: bootc machines move forward, and rollback is
the safety net.
