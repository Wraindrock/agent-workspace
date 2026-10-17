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
- **The `incus` backend hands the workspace to a host daemon.** With `--backend
  incus` the workspace is an unprivileged Incus instance: `incusd` owns its lifecycle, its disk
  devices and its `proxy` device. The host-level setup that makes the daemon usable
  (`sudo systemctl enable --now incus.socket`, `sudo incus admin init --minimal`) is
  deliberately left to you: `install.sh` never runs `sudo`, never writes under `/etc`
  and never starts a daemon. The instance's root is a sub-uid/sub-gid of your user,
  so container root is not host root, exactly as with the container backends; agent
  credentials reach the daemon on stdin (`config set <name> environment.KEY -`)
  instead of on a command line, so they stay out of `ps` and the shell history.
- **The `kvm` backend is a VM boundary, not a container boundary.** A `kvm`
  workspace is a QEMU process run by `virsh --connect qemu:///session` as your user,
  with its own guest kernel and root filesystem, no host directory mounted and no
  container runtime in the path. Root inside the guest is guest root: it does not
  become host root, and a guest kernel compromise has to escape QEMU/KVM before it
  reaches this host. Two honest limits: KVM is a Linux kernel feature, so the host
  kernel is still in the TCB (a QEMU/KVM or hardware vulnerability reaches the host,
  exactly like a container escape but through a different surface); and the default
  `qemu:///session` keeps the domain running as your user with user-mode networking,
  which is why only loopback forwards are created. `qemu:///system` is opt-in -
  it hands the domain to the system libvirt daemon and its `qemu` user - and it is
  never selected automatically. The per-instance SSH private key is stored host-side
  at `${AW_KVM_ROOT:-...}/<name>/id_ed25519` with mode 0600, only the public key is
  injected into the guest; the seed ISO that carries it stays next to the disk
  (it contains the public key, not a secret). The serial console has root
  autologin on `ttyS0` inside the guest: anyone who can already run commands as
  this host user can attach to it, so it adds no host-side power - but it does mean
  guest root is reachable without the SSH key, and the console log written next to
  the disk can contain whatever the guest printed.
- **The presentation channel is one loopback forward, never a mount.** A URL
  requested inside an instance reaches the host only because the backend publishes
  exactly one host port on `127.0.0.1`: `--publish 127.0.0.1:<port>:3080` for
  containers, a `proxy` device bound to `127.0.0.1` for Incus, and
  `hostfwd=tcp:127.0.0.1:<port>-:3080` (plus the SSH forward) for KVM. Nothing is
  copied out of the instance to make a page load, the forwarded port is never bound
  to a non-loopback address by this installer, and the address the user opens is
  always `127.0.0.1:<port>`. The forward exposes whatever the agent chose to serve
  on that port; the traffic is plain HTTP on loopback, so a shared host user can
  read it - do not serve secrets to a host you do not trust.
- **Data lives inside the instance, and the engine volume is not a host
  boundary.** `install.sh` no longer bind-mounts a host directory into an
  instance: the agent works in `/home/agent`, which is a named engine volume for
  `podman`/`docker`, the instance disk plus the installer-managed
  `~/.local/share/agent-workspace/incus/homes/<name>` directory for `incus`, and the
  instance's qcow2 for `kvm`. That storage is engine-managed and survives the
  instance, but it is **not** secret
  from the host user: a rootless engine runs as you, and `incusd`'s home
  directory is a normal host directory. It protects your data from a damaged
  instance, not from the host account. `backup` archives are plain `tar.gz` files
  (written with mode `600`) and contain whatever is in `/home/agent`, including
  any token the agent stored there; treat them like credentials, and validate
  their contents before restoring an archive you did not create. `restore`
  validates the archive and takes a pre-restore clone, and `rescue` exposes a root
  shell inside the instance - they widen what the host user can do to instance
  data, not the instance's boundary against the host.
- **Inside the container, nothing confines the agent.** `install.sh enter` and
  `shell` `exec` into the container as its default user, which is root: this
  installer never creates a container with `--user`. Only the web UI drops to the
  `agent` user, which first boot additionally puts in the `wheel` group
  (`runtime/lib/firstboot.sh:24`) and gives a sub-id range for rootless podman.
  So the agent can edit `/etc`, `dnf install` and run rootless containers. `sudo`
  is installed, but the base image keeps Fedora's stock `%wheel ALL=(ALL) ALL`, which
  wants a password the created `agent` account does not have; no passwordless
  escalation is configured at build or first-boot time. The one deliberate exception
  is `./install.sh root <name> on`, which installs
  `/etc/sudoers.d/agent-workspace` (`NOPASSWD`) for the agent user only: it is off by
  default, `off` removes the rule, rotates the account password and locks it, and the
  password is never echoed. Root inside the instance is the **same trust domain as
  the agent**: it is container root, never host root. On podman/docker it still sits
  behind the host-kernel caveat above; on incus the instance's root is a sub-uid of
  your user. Turning it on widens what an agent mistake can reach inside the instance;
  it does not weaken the container-to-host boundary. The image layers stay
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
- **The default DSH plugin set is third-party code.** The image ships eleven
  third-party npm plugins as a pre-installed DSH profile
  (`build_files/modules/45-dsh-plugins`, sources under
  `system_files/usr/share/agent-workspace/dsh/profiles/web`). They are pinned by a
  committed `pnpm-lock.yaml` and installed with `--frozen-lockfile`, so what ships is
  exactly what the lockfile resolves to - but a lifecycle script runs as root during
  the image build, and the plugin code then runs inside the agent's container with
  the agent's privileges. Reviewing a plugin means reviewing that lockfile and the
  plugins it names. Turn the module off (`45-dsh-plugins=0` in
  `config/modules.conf`) for a build that should not carry them, and keep in mind
  that the agent's own `dsh plugin add` installs more of the same, unpinned.

## Supported versions

Only the newest published tag (and the newest dated tag) receives fixes. There
are no long-term support branches: you move forward with `install.sh upgrade`,
and rollback to a snapshot is the safety net.
