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
| `install.sh` and the container lifecycle it drives | Vulnerabilities in podman or docker themselves |
| The `agent-workspace` CLI and its systemd units | The agent CLIs' own behaviour with your credentials |
| CI/CD: what can push to GHCR, what can sign | Your GHCR repository settings and personal access tokens |
| Secrets hygiene in the repository | Operator mistakes such as committing keys to a fork, or choosing `--engine docker --privileged` on a host you do not trust the container with |

## Design decisions that affect security

- **No credentials in the image.** Agent API keys, tokens and SSH keys are never
  baked in; the smoke test and lint run without any secrets present.
- **Keyless signing by default.** Releases are signed with a short-lived
  certificate bound to the workflow identity, so there is no long-lived private
  key to steal. `cosign verify` with an identity regexp is the recommended
  verification path. Key-based signing (a `SIGNING_SECRET` repository secret) is
  supported for fleets that verify against a pinned public key.
- **Containers share the host kernel.** A container started by `install.sh` is
  an isolated filesystem and process tree, not a virtual machine: a kernel
  vulnerability, or a container deliberately run with `--privileged` (which the
  `docker` engine path needs for systemd), reaches the host. Use `podman`
  (rootless) when the agent is not fully trusted, and prefer a virtual machine
  when the boundary must be hard.
- **Inside the container, nothing confines the agent.** `install.sh enter` and
  `shell` `exec` into the container as its default user, which is root: this
  installer never creates a container with `--user`. Only the web UI drops to the
  `agent` user, which first boot additionally puts in the `wheel` group
  (`runtime/lib/firstboot.sh:24`) and gives a sub-id range for rootless podman.
  So the agent can edit `/etc`, `dnf install` and run rootless containers. `sudo`
  is installed too, but this repository ships no `sudoers`/`NOPASSWD` override and
  the base image keeps Fedora's stock `%wheel ALL=(ALL) ALL`, which wants a
  password the created `agent` account does not have. The image layers stay
  immutable and the writable layers belong to the container, so the blast radius
  of an agent mistake ends at `install.sh remove <name>` - but the container is
  not a security boundary against the agent itself.
- **The container layer is writable by design.** Whatever the agent installs or
  edits in `/etc` or `/usr/local` persists for the life of the container and is
  captured by `install.sh snapshot`. Treat `install.sh rollback` on a container
  you did not build yourself as restoring someone else's content.
- **Unqualified container names are permissive.** The registries drop-in enables
  short names so agents can `podman run alpine` without ceremony; if your threat
  model dislikes that, turn it off in `system_files/etc/containers/registries.conf.d/00-agent-workspace.conf`.

## Supported versions

Only the newest published tag (and the newest dated tag) receives fixes. There
are no long-term support branches: you move forward with `install.sh upgrade`,
and rollback to a snapshot is the safety net.
