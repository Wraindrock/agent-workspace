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
| `kvm` | recommended when `/dev/kvm` exists | a complete system: own kernel, init and modules, so operations that need them work. Heavier: an image has to be built into a bootable disk, and memory/disk are given up for real. |
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
- `kvm` is listed as the recommendation and marked "not implemented" until a
  backend-kvm.sh exists; it is never selectable, which is what the list says.
- `--dry-run` on a host with no recorded choice assumes podman and says so: it is
  planning, not doing, so it is the one path that does not refuse.
- `tests/install.sh` asserts all of the above as behaviour: non-interactive refusal
  with the list, remembered choice honoured, interactive chooser via a real pty,
  mode-600 storage, gate errors for both entry points, and `list`/`doctor`
  availability output.

## Instance root is a live boolean, not a one-time grant

An agent that cannot install a package or start a service is blocked; an agent
with permanent root is a standing risk. The balance is a switch the user can
flip at any time in either direction:

- `./install.sh root <name> on|off` — effective immediately, no restart.
- default `off` (which is also today's effective behaviour: the agent is in
  `wheel` but `sudo` needs a password the agent does not have).
- The agent account is created with a **high-entropy random password** that
  nobody needs day to day: it makes password-`sudo` technically available to the
  user while being unusable by the agent, which cannot read it (the value lives
  in a root-only `0600` file inside the instance and is never printed by the
  installer — only its location is).
- `on` writes an escalation rule for **the agent user only**
  (`/etc/sudoers.d/agent-workspace`, `NOPASSWD`) inside the instance; `off`
  removes it. `sudo` re-reads `sudoers.d` on every invocation, so the switch is
  effective on the agent's **next** `sudo`, with no re-login and no restart.
- Turning the switch off **rotates the agent's password**. While the switch was
  on the agent had full root and could have read the stored password; rotating
  it means nothing learned during the window still works afterwards. The switch
  is therefore genuinely reversible, not one-way.
- The instance records the *desired* state (what the user asked for) and the
  *observed* state (what the instance actually has); a failed probe updates only
  the observed side.
- `./install.sh status` shows the current value, and the toggle is logged.

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
agent home, workspace, sessions — lives in the instance's own storage:

- containers: named volumes owned by the container engine, not a bind mount of a
  host path;
- VMs: the instance's own disks.

So a damaged environment can be thrown away without having ever held the user's
data hostage, and the two backends have the same data model.

What replaces host sharing is **rescue**: `backup` writes a verified archive of
an instance's data plus a manifest (image reference/digest, configuration),
`restore` validates that archive before restoring, and `rescue` starts a
throwaway instance with the volumes attached so data can be pulled out of an
environment whose root filesystem no longer boots. Archives are verified after
writing (listable, contains the required members) and the source is validated
before restoring; both print counts, not just "done".

## Incus: visible, not hidden, not selectable

`backend-incus.sh` stays in the tree, stays in the backend list, and stays under
test. What is gated is *selectability*: `auto` does not exist, and
`--backend incus` fails with a message explaining that this host system cannot
enable it yet and how it is turned back on. It is a gate, not a deletion, so
enabling it later is one step.

## Not in this version (deliberate non-goals)

- **Converting an instance into a desktop system** driven interactively through
  QEMU (GUI/desktop session on top of a selected instance). Planned; not
  implemented.
- Replacing the host: installing to bare metal, managing host packages or
  booting the host from this project.
- Sharing host directories into an instance: not a capability of this version.
