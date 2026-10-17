# Backend model

This document records the design decisions behind how agent-workspace picks and
runs a backend. It is the reference for the implementation; where the code and
this document disagree, one of them is a bug.

## What the product is

An agent-workspace is an **isolated development environment for an agent**. The
host provides capability; it is not managed, configured or replaced by this
project. Every backend is a way to obtain that isolation, and none of them is
better because it looks more like a whole machine.

## Two axes of privilege (do not conflate them)

| Axis | Rule |
| --- | --- |
| **Host side** | Rootless by principle: no system service, no system directory, no `sudo` needed to install or run. The point is that the main system is not touched. |
| **Inside the instance** | Root is available and useful. It is guest/container root, not host root, and whether the agent has it is the user's live decision (see below). |

For a rootless container, root inside is a mapped uid; for a VM, root inside is
the guest's root. Neither changes host-side containment: the host is still not
root, still not modified.

## Backend selection: no `auto`

There is deliberately **no automatic backend choice**. Probing the host and
silently picking a backend hides a trade-off that the user is the only one who
can weigh.

- `./install.sh create …` without `--backend`:
  - interactive: print the backend list with recommendations and trade-offs and
    let the user choose; remember the choice for next time;
  - non-interactive: fail and print the same list. No silent pick.
- `--backend NAME` always wins and never writes back to the remembered choice.
- `./install.sh backend` shows the remembered choice; `./install.sh backend set NAME`
  changes it.
- The remembered choice is a convenience for a decision the user already made,
  not an auto-detection: a *new* user with no recorded choice is still asked.

The list itself carries the comparison:

| Backend | Status | Trade-offs |
| --- | --- | --- |
| `kvm` | **implemented**; recommended when `/dev/kvm` exists | a complete system: own kernel, init and modules, so operations that need them work. Heavier: an image has to be built into a bootable disk, and memory/disk are given up for real. Runs under libvirt (`qemu:///session`, rootless user-mode networking). |
| `podman` | recommended, lightest start | shares the host kernel. Fast, cheap, no preparation; some operations are structurally impossible inside it. |
| `docker` | alternative to podman | same kernel-sharing trade-off; useful where docker is already the host's tool. Needs `--privileged` for an in-container init. |
| `incus` | present, **not selectable for now** | LXC system containers managed by a daemon. Kept visible and implemented; it becomes selectable again by turning the gate off (see below), which currently requires a different host system. |

### Implementation notes (where this lives in the code)

- The decision order is `--backend` (explicit, never written back) -> remembered
  choice -> interactive chooser -> non-interactive refusal, implemented by
  `resolve_backend_choice` in `install.sh`; the list itself is `backend_list` in
  `installer/lib/engine.sh`.
- The remembered choice is `${XDG_CONFIG_HOME:-~/.config}/agent-workspace/backend`
  (mode 600, written with a same-directory temp file and `rename`), read/written by
  `state.sh`; `./install.sh backend` and `backend set NAME` are `cmd_backend` in
  `commands.sh`.
- The gate is the variable `BACKEND_GATED` in `installer/lib/engine.sh` (default
  `incus`); `AW_ENABLE_BACKEND_INCUS=1` is the escape hatch the gate checks first,
  and removing `incus` from `BACKEND_GATED` is the one-step way back to a selectable
  incus.
- `kvm` is implemented by `installer/lib/backend-kvm.sh`; it is a normal,
  selectable backend. A host does not have a `kvm` binary, so `backend_bin` maps
  the name to `virsh` for the presence check, and `backend_ready` runs
  `kvm_probe` (device, libvirt URI, tools, storage) instead of `virsh --version`.
  `AW_KVM_URI` (default `qemu:///session`) and `AW_KVM_ROOT` (default
  `~/.local/share/agent-workspace/vms`) are the documented overrides;
  `AW_KVM_DEVICE` exists only so the test suite can run without `/dev/kvm`.
- `--dry-run` on a host with no recorded choice assumes podman and says so: it is
  planning, not doing, so it is the one path that does not refuse.
- `tests/install.sh` asserts all of the above as behaviour: non-interactive refusal
  with the list, remembered choice honoured, interactive chooser via a real pty,
  mode-600 storage, gate errors for both entry points, and `list`/`doctor`
  availability output.

## Instance root is a live boolean, not a one-time grant

An agent that cannot install a package or start a service is blocked; an agent
with permanent root is a standing risk. The balance is a switch the user flips at
any time in either direction:

- `./install.sh root <name> on|off|status`; `status` is the default word. The
  change is effective immediately: no restart and no re-login.
- default `off`. The image puts the agent in `wheel`, but stock
  `%wheel ALL=(ALL) ALL` wants a password the account does not have, and neither
  the build nor first boot writes a passwordless rule.
- `on` writes `/etc/sudoers.d/agent-workspace` for the agent user only
  (`agent ALL=(ALL) NOPASSWD: ALL`, mode 0440), creating `/etc/sudoers.d` (0750)
  first when the image lacks it. The rule is written to a temporary file in the
  same directory, validated with `visudo -cf`, and only then installed: a rejected
  file is removed and the command fails without ever touching the live rule.
- `on` also gives the agent account a fresh 32-hex-character password via
  `chpasswd` (fed on stdin, so it never appears in `argv` or the engine log) and
  unlocks the account, then stores the value host-side at
  `${XDG_CONFIG_HOME:-~/.config}/agent-workspace/credentials/<name>.root` (0600,
  directory 0700, written to a temporary file and renamed). Only the path is
  printed, never the password. `off` deletes it again and reports the count.
- `off` removes the rule, rotates the password to a new random value that is
  written nowhere, locks the account (`passwd -l`) and deletes the host file; it
  then verifies that `sudo -n true` fails. Rotating is what makes the revoke
  meaningful: while the switch was on the agent had root and could have read the
  stored password, so nothing learned in that window keeps working.
- The probe is `su -s /bin/sh -c 'sudo -n true' agent`, run through the backend's
  exec verb - so it is one plain argv for containers and instances alike, and it
  behaves like a real login (including refusing a locked account). `status`
  reports the live answer and whether the rule file is present, and warns when
  the two disagree: the file is *requested* state, `sudo` is *observed* state. A
  stopped instance is refused with the command that starts it, never guessed.
- Both directions are idempotent: `on` when already on and `off` when already off
  re-verify and report that, changing nothing. `off` does **not** revoke
  already-running processes: root processes the agent started keep their
  privilege until they exit.
- The host stores nothing else for this switch, and it does not rewrite the
  credentials file on a failed probe: the file exists only while the switch is
  on. All of the state that matters lives inside the instance.

Why a per-user `sudoers.d` rule and not group membership: adding the agent to a
privileged group does not affect the sessions it already has — the change only
lands after a new login (or after killing those sessions), which is exactly the
"privilege did not take effect immediately" surprise. A file-based rule named
after the agent user is also narrower and easier to audit than a group.

## Presentation: an instance borrows the host's browser

Work produced inside an instance has to reach the user's eyes, and the user's
eyes are on the host. This is a **display channel, not data sharing**: nothing is
mounted, no host directory is exposed. What crosses the boundary is a URL, over a
loopback port.

Two directions are needed, and both must work through nested instances (a VM
inside a VM):

1. **Outward request** — "open this in the user's browser." The instance asks its
   own gateway (in user-mode networking that is the host's loopback), so a nested
   instance asks its parent, the parent asks the host, and the request walks up
   the chain. The host side of the chain is a per-user, rootless helper that owns
   the browser: it opens the URL (and nothing else — it is not a command
   executor). Requests carry a per-instance token so only this project's
   instances can ask. If no helper and no browser is present, the URL is printed
   instead, so a headless host degrades rather than fails.
2. **Inward reach** — the browser has to load the service. Each layer forwards
   one loopback port to its parent (`hostfwd`-style), so `./install.sh web <name>`
   programs a *chain* of forwards and the final address is always
   `127.0.0.1:<port>` on the host.

This is the same mechanism for containers and VMs; only the "how do I reach my
host" detail differs.

GUI presentation (a real desktop session rendered in the host's browser, e.g.
noVNC/SPICE) is **not** this channel — it is part of the desktop-conversion
feature listed under the non-goals below.

## Management surface (host side): a TUI

The CLI stays authoritative and complete. Management is a **terminal UI** — a
front-end over the same verbs, never a new source of truth, and never a
requirement for using the tool.

- One uniform surface for what the user has to decide: the backend chooser
  (recommendations and trade-offs — no `auto`), the live instance-root switch,
  backup/restore/rescue, logs and status, instance lifecycle.
- It runs in the user's terminal, as the user: no host root, no system service,
  nothing listening on the host. It calls the same code the CLI calls.
- It owns **presentation**: when an instance wants to show something, the TUI is
  the surface that hands the URL to the user (and may open it in the host's
  browser via the desktop's own handler). Reading a pending request needs only
  the engine's exec path — `exec` for containers, the guest agent for VMs — so
  there is no host-side daemon and no per-instance token to manage.
- It inherits the project's rules: credentials only through `0600` surfaces and
  never rendered, destructive actions ask for literal confirmation, expected and
  observed state are shown separately, and no choice is made silently on the
  user's behalf.

A **Web UI** is deliberately not part of this version: it will be specified
separately later (the interface above keeps the seam clean for it). A desktop
GUI/AppImage is **not planned**: this project is to be merged into the
WrainrockLab project, which will own that concern, so building one here would be
work without a consumer.

## Data lives inside the instance

Nothing in a working instance is a host directory the user browses. All data —
agent home, working tree, sessions — lives in the instance's own storage:

- containers: one named volume owned by the container engine, mounted at
  `/home/agent`; no bind mount of a host path, and `/workspace` is not created
  from the host any more - the agent works in `/home/agent`;
- incus instances: the instance's own disk, plus the installer-managed home
  directory at `~/.local/share/agent-workspace/incus/homes/<name>`. That
  directory is engine-attached storage the installer owns and validates, not a
  user-selected workspace folder, but it is honest to say the host user can read
  it;
- kvm instances: one qcow2 disk under
  `~/.local/share/agent-workspace/vms/<name>/disk.qcow2`; the agent's home lives
  inside the guest filesystem, so there is no host directory to browse. The
  per-instance directory also holds the SSH key (0600), the cloud-init seed ISO
  and the serial console log, all user-owned.

So a damaged environment can be thrown away without having ever held the user's
data hostage, and every implemented backend has the same data model: the
installer mounts only engine-managed storage.

Moving data is explicit, never implicit. `backup NAME [--to FILE]` archives the
in-instance home plus a root `manifest.txt` (instance name, mode, agent, engine,
image reference and digest when known, UTC creation time, required data markers).
The archive is written to a `.partial` name, verified by listing it and asserting
`manifest.txt` and the home data are members, then renamed; a failed check deletes
the partial file and exits non-zero. It refuses to overwrite an existing file and
prints the path with its member count.

`restore NAME ARCHIVE [--skip-safety]` validates the source archive first (readable
tarball, `manifest.txt`, home data), refuses a running instance and names the exact
`./install.sh stop NAME` command, then clones the current home volume to
`<volume>-pre-restore-<UTC timestamp>` unless `--skip-safety` is given, reporting
the clone name and entry count. It restores through the backend helper, verifies
the volume exists afterwards, and reports how many entries were restored.

`rescue NAME [--copy PATH]` is for the locked-out case: a stopped instance is
started first, then either an interactive root shell is opened inside it
(`eng_exec_root`, requires a TTY) or one path is copied out to the current host
directory through a temporary volume tar. It refuses an unknown instance and a
path outside the instance home. `--dry-run` on all three prints the plan and
writes nothing. Counts and the resulting paths are printed, not just "done".

## Incus: visible, not hidden, not selectable

`backend-incus.sh` stays in the tree, stays in the backend list, and stays under
test. What is gated is *selectability*: `auto` does not exist, and
`--backend incus` fails with a message explaining that this host system cannot
enable it yet and how it is turned back on. It is a gate, not a deletion, so
enabling it later is one step.

## KVM: the OCI image as a bootable VM

`backend-kvm.sh` boots the same OCI image under KVM through libvirt. It is not a
cloud image with the project installed on top: the image's own rootfs and its own
bootc kernel are made bootable, exactly like the container backends use the
image's own userland.

### Host preparation (one-time, and never done by `install.sh`)

The probe names every missing item and appends the package command for Fedora and
Arch; selection refuses with that list. It checks, in one read-only pass:

- `/dev/kvm` exists and is readable/writable (or `/dev/kvm` is absent because
  nested virtualisation is off);
- `virsh`, `qemu-img`, `virt-install`, `xorriso`, `mkfs.ext4`, `ssh`, `ssh-keygen`
  are on `PATH` (each missing one is named);
- `virsh --connect qemu:///session version` answers;
- a container helper (`podman` or `docker`) exists to export the OCI image;
- `unshare -r` can create a user namespace (util-linux; `podman unshare` is the
  fallback);
- the storage root's nearest existing parent is writable.

The default URI is `qemu:///session`: rootless, user-mode networking, no system
service. `AW_KVM_URI=qemu:///system` is the explicit opt-in for a host where
session mode cannot boot. Storage is `${AW_KVM_ROOT:-${XDG_DATA_HOME:-$HOME/.local/share}/agent-workspace/vms}`,
owned by the user; `/var/lib/libvirt/images` is deliberately not used.

### Build path (proven; this is what the backend implements)

1. **Export the rootfs.** `podman create` + `podman export` (or the docker
   equivalent) into a tar; extract under the image cache
   (`vms/images/<sanitised-ref>/`) inside the same unprivileged user namespace.
   The extraction step matters: a plain user extraction silently strips setuid
   bits, which leaves `sudo` unusable in the guest; inside the namespace tar
   restores the image's root-owned modes. `podman run` is not required.
2. **Use the image's own kernel.** A bootc image ships
   `/usr/lib/modules/<version>/{vmlinuz,initramfs.img}`; the backend copies them
   into the image cache as `vmlinuz`/`initramfs.img`. An image without them is
   refused with that reason instead of building something silently unbootable.
3. **Make an ext4 disk, rootless.** `truncate` a sparse raw image and run
   `chown -R 0:0` + `mkfs.ext4 -d <rootfs>` as uid 0 inside an unprivileged user
   namespace (`unshare -r`; `podman unshare` when unshare is unavailable). The
   namespace is what makes root-only modes such as `/etc/gshadow` (0000) readable
   and records root ownership, without host root; fakeroot is not enough here
   because it fakes chown/stat but cannot grant that DAC override. Convert the raw
   image to qcow2 with `qemu-img convert`. The files stay owned by you, so QEMU can open
   them; nothing is ever created as host root.
4. **Seed with cloud-init.** A per-instance ed25519 key pair is generated at create
   time (private key 0600, host side) and injected through a NoCloud seed ISO
   (volume label `cidata`, built with `xorriso`): the `agent` user in `wheel`
   (sudo stays password-gated until `root on` writes its rule, exactly like the
   container backends) and the public key. The environment file is pushed over
   SSH after the guest answers, so it is not baked into the seed. The seed also
   installs a small script that opens the presentation port in the guest
   firewall: user-mode networking makes the guest see the host as `10.0.2.0/24`,
   and the distro firewall otherwise drops the forwarded request (the symptom
   is a TCP connect that succeeds while HTTP hangs). cloud-init is
   part of the image build now (`cloud-init` in
   `build_files/modules/10-base-packages/install.sh`); an image built without it
   is refused with the reason, because the key could not reach the guest.
5. **Define the domain.** Direct-kernel boot of the rootfs: `<kernel>`, `<initrd>`,
   kernel args `root=/dev/vda rw console=ttyS0`, a virtio-blk disk, `--graphics
   none`, a serial file log, and user-mode networking with
   `hostfwd=tcp:127.0.0.1:<ssh-port>-:22` and
   `hostfwd=tcp:127.0.0.1:<web-port>-:3080`. The XML template is generated per
   instance and defined with `virsh define`. The `<qemu:commandline>` element
   must be a direct child of `<domain>` (libvirt silently ignores it inside
   `<devices>`), and the custom virtio-net device needs an explicit free PCI
   slot (`bus=pcie.0,addr=0x6`): without it QEMU picks slot 1, which libvirt has
   already given to a PCIe root port, and the domain refuses to start with
   `PCI: slot 1 function 0 not available`.
6. **Wait without sleeping.** A bounded poll (not a fixed sleep) waits for the
   domain to run, then for SSH to answer with the instance key
   (`BatchMode`, `ConnectTimeout`), then for
   `/var/lib/agent-workspace/.provisioned`; each timeout prints the tail of the
   serial console and the path of the full log.

### The proven boot (captured evidence)

Phase A booted the exported image's rootfs directly with QEMU/KVM, outside the
backend, to prove the disk+kernel path before implementing it. The proof ran in the
development distrobox; the serial console log is saved there as
`~/.local/share/aw-phasea/evidence/console-direct-boot.log` and contains exactly
one `fedora login:` line. The command was:

~~~bash
D=$HOME/.local/share/aw-phasea
virt-install --connect qemu:///session --name aw-proof --memory 4096 --vcpus 4 \
  --cpu host-passthrough --import \
  --disk path=$D/disk.img,format=raw,bus=virtio,cache=none \
  --boot kernel=$D/boot/vmlinuz,initrd=$D/boot/initramfs.img,\
kernel_args="root=/dev/vda rw console=ttyS0,115200 selinux=0 enforcing=0" \
  --network user,model=virtio --graphics none \
  --serial file,path=$D/console.log --osinfo detect=on,require=off \
  --noautoconsole --wait 0 --check path_in_use=off
~~~

The disk was a 16 GiB sparse ext4 image built with
`mkfs.ext4 -q -F -L aw-root -d <rootfs>`, and the kernel was the image's
7.2.10-200.fc44.x86_64 bootc kernel. The console reached multi-user:

~~~text
  Welcome to Fedora Linux 44.20261014.0 (Forty Four)!
  ...
  [ OK ] Reached target basic.target - Basic System.
  [ OK ] Reached target ssh-access.target - SSH Access Available.
  Fedora Linux 44.20261014.0 (Forty Four)
  Kernel 7.2.10-200.fc44.x86_64 on x86_64 (ttyS0)
  fedora login:
~~~

`bootloader-update.service` failed in that boot (benign: the bootc image has no
bootloader), and `ostree-remount.service` was skipped because
`ConditionKernelCommandLine=ostree` was unmet — both are expected for a plain
`root=/dev/vda` boot and do not stop multi-user. cloud-init was not yet in that
image; the backend now builds it in. The backend was then exercised end to end in
the same session: cloud-init created the agent user, the per-instance key reached
the guest, the first-boot marker and SSH were reached by the bounded poll, the web
server on guest port 3080 answered on the host's loopback forward, `backup`
streamed the home out over SSH, and the serial console still had the root
autologin for rescue. The evidence is in
`~/.local/share/aw-phasea/evidence/` (`console-direct-boot.log`,
`e2e-create.log`, `e2e-backup.log`); `tests/kvm.sh` asserts every layer with fake
`virsh`/`qemu-img`/`ssh` binaries so CI needs no `/dev/kvm`. `qemu:///system`
remains unverified by choice (rootless session mode is the default).

### Lifecycle and data

- `create/start/stop/status/destroy` are libvirt domain lifecycle operations;
  `list` and `doctor` read the recorded state as for any instance.
- `enter` (and a non-interactive command) is SSH to the agent user on the
  per-instance loopback port, inside a login shell; `root`/`rescue` use the serial
  console (`virsh console`), where the seed enables root autologin on `ttyS0` so a
  wedged guest is still reachable. `logs` tails the serial log.
- Data is the qcow2, full stop. `backup` streams `/home/agent` out of the guest
  over SSH into a verified archive; `restore` boots a stopped instance, streams the
  archive back, and stops it again; `snapshot`/`commit` shut the domain down
  gracefully, convert the disk to a new qcow2 with `qemu-img`, and restart it;
  `fork`/`rollback` use the same archive buffer as the containers.
- The **presentation channel** is one loopback forward per layer: guest port 3080
  is published as `hostfwd=tcp:127.0.0.1:<port>-:3080`, so a URL requested inside
  the VM is loaded from the host at `127.0.0.1:<port>`. Nothing is copied out of
  the guest to make that work.
- Deliberately not implemented: `ephemeral` mode (booting a VM to run one command
  wastes the point of a VM), a GUI/desktop session (the project's desktop
  non-goal), and SSH authentication by anything other than the per-instance key on
  loopback. `AW_KVM_URI=qemu:///system` is opt-in, never automatic.

## Not in this version (deliberate non-goals)

- **Converting an instance into a desktop system** driven interactively through
  QEMU (GUI/desktop session on top of a selected instance). Planned; not
  implemented.
- Replacing the host: installing to bare metal, managing host packages or
  booting the host from this project.
- Sharing host directories into an instance: not a capability of this version.
