# Snapshots, rollback, recover and fork

A container created by `install.sh` is a whole operating system with the agent's
state inside it. The installer can therefore treat it the way you would treat a
virtual machine: commit it, come back to it, rebuild it, or branch a new one off it.
Nothing here touches the host's own bootc/ostree deployments - the unit of rollback
is the container.

## What a snapshot contains

`./install.sh snapshot dsh-box` does two things:

1. commits the container's filesystem to a local image
   `agent-workspace/snapshot-<name>:<id>`, and
2. archives the container's home volume to
   `${XDG_DATA_HOME:-$HOME/.local/share}/agent-workspace/snapshots/<name>/<id>/home.tar.gz`.

The id is a UTC timestamp (`20260113T090000Z`), and each snapshot directory carries a
`meta` file with the container, agent, mode, workspace, image and label it was taken
with. The newest `5` snapshots are kept by default (`--keep N` or `SNAPSHOT_KEEP`).

Labels are recorded for you: `manual` for snapshots you take, `pre-upgrade` for the
snapshot `upgrade` takes automatically, `pre-rollback` for the safety snapshot
`rollback` takes, and `fork-source` for the one `fork` takes before branching.

~~~bash
./install.sh snapshot dsh-box --label before-refactor
./install.sh snapshots dsh-box
~~~

## Rollback

`rollback` replaces the container with a snapshot: it stops and removes the current
container, restores the home volume from the snapshot's archive, and starts a new
container from the snapshot image with the same name, agent, mode and workspace.

~~~bash
./install.sh rollback dsh-box                  # the latest snapshot
./install.sh rollback dsh-box --to 20260113T090000Z
./install.sh rollback dsh-box --skip-safety    # do not snapshot the old container
~~~

A rollback is itself undoable. Before it changes anything it checks that the
snapshot's home archive can really be read back (`tar -tzf`), so a truncated or
half-written archive stops the command with nothing touched. Then it snapshots the
container it is about to replace, labelled `pre-rollback`, and only then removes and
recreates it; `--skip-safety` turns that snapshot off when you already have what you
need - for example when the container you are replacing is broken.

The snapshot image must still be in the local engine store - these images are local
by design and are never pushed to a registry. If it is gone, the installer stops and
tells you; the home archive alone cannot rebuild the filesystem.

## Recover

`recover` is the answer to "something happened to my container". It picks the right
response by itself:

| Situation | What `recover` does |
| --- | --- |
| the container is running | nothing - it says so and exits |
| the container exists but is stopped | starts it again |
| the container is gone and a snapshot exists | restores the latest snapshot (volume included) |
| the container is gone and there is no snapshot | rebuilds it from the recorded image, keeping the home volume |

~~~bash
./install.sh recover dsh-box
~~~

## Fork

`fork` creates a second container from the state of the first one, with its own home
volume and its own credentials file:

~~~bash
./install.sh fork dsh-box dsh-experiment
./install.sh fork dsh-box dsh-old --from 20260113T090000Z   # from a specific snapshot
./install.sh fork dsh-box dsh-live --live                   # copy the live volume, no snapshot
./install.sh fork dsh-box dsh-alt --agent opencode --workspace ~/work/alt
~~~

By default the source is snapshotted first (`fork-source`), and the new container's
home is unpacked from that archive; `--live` copies the running volume instead. The
new container records `FORKED_FROM` and `FORKED_AT` in its metadata. Credentials are
copied so the fork is immediately usable, with a warning to review the new file.

## Upgrade

`upgrade` moves a container to a newer image while keeping its identity:

~~~bash
./install.sh upgrade dsh-box --image ghcr.io/wraindrock/agent-workspace:latest
~~~

It takes a `pre-upgrade` snapshot first, then recreates the container from the new
image with the same name, agent, mode and workspace, and reuses the home volume. If
the new image misbehaves:

~~~bash
./install.sh rollback dsh-box --to <the pre-upgrade id>
~~~

## Snapshots the installer will not delete

Snapshots are local images, and local images can be in use. When retention (`--keep`)
or `remove --purge-snapshots` needs to delete one, the installer asks the engine
first:

- if a container still runs from the snapshot's image - including a container this
  installer does not manage - the snapshot and its archive are kept and the reason is
  printed together with the container name;
- `remove --purge-snapshots` reports how many snapshots it kept for that reason
  instead of forcing the image away, so the number is never silently wrong;
- if the image cannot be removed for any other reason, the snapshot metadata and
  archive stay too. Remove the container it names (or `podman rmi` it yourself) and
  the next prune takes it.

`snapshot` applies the same idea to its own output: it reads the home archive it just
wrote and deletes it again if the read fails, keeping the filesystem snapshot, so no
snapshot can silently restore a half-written home directory.

## What snapshots do not cover

- **The host workspace.** `/workspace` is a bind mount of a directory on your host;
  it is your data, and it is not part of a snapshot. Version it with git.
- **Credentials.** They stay in `~/.config/agent-workspace/containers/<name>.env` and
  are deliberately kept out of the container filesystem and out of snapshots.
- **Other hosts.** Snapshots are local images plus a local archive. To move a
  container elsewhere, `snapshot`, then save the image and the archive and load them
  on the other machine - or rebuild the container from the declaration file.
- **A damaged local store.** The snapshot image lives only in your engine's storage
  and the home archive only on this host. If either is lost (somebody ran `podman
  rmi`, the disk holding it failed), the installer stops and tells you instead of
  handing you a half-restored container: the archive alone cannot rebuild a
  filesystem, and the image alone cannot rebuild your home volume. `./install.sh
  doctor --strict` is the cheap check - it verifies that the recorded images still
  exist and that every snapshot archive is a readable tarball.
- **Your host system.** Nothing in this project updates, pins or rolls back the OS
  you are running the containers on. That is your distribution's job.
