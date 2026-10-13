# Containers on your host

The published image is a complete operating system, so the fastest way to use it
is a container: one OS per agent, isolated from your workstation. `install.sh` in
the repository root creates those containers for you - interactively or from a
declaration file - and keeps each container's credentials in its own private
environment file.

## Requirements

* `podman` (rootless is the recommended setup; the installer never needs sudo)
* `bash` 4 or newer
* an image that can be pulled - `ghcr.io/wraindrock/agent-workspace:latest` by default

## Quick start

~~~bash
./install.sh                # interactive wizard
./install.sh --list         # what this host already has
./install.sh --help         # every option
~~~

The wizard asks how many containers you want. For each one it asks:

| Question | Meaning |
| --- | --- |
| agent | which harness inside the image the container starts: `dsh`, `opencode`, ... |
| name | container name, and the prefix of its volume and env file (`dsh-box` by default) |
| lifecycle | `persistent` (systemd, survives reboots) or `ephemeral` (one-shot, removed on exit) |
| workspace | host directory bind-mounted at `/workspace` |
| credentials | the API key the chosen agent needs, when it is not already in your environment |

The agent list comes from the image itself: `manifest.json` inside the image carries
an `agentCatalog`, so the menu offers exactly what that build ships. When the image
cannot be inspected, the installer falls back to a small built-in table.

## The two lifecycles

`persistent` starts a detached container with systemd as PID 1 and a named volume
for `/home/agent`:

~~~bash
podman exec -it dsh-box bash -lc 'dsh'   # step into the running container
podman stop dsh-box                      # stop it without deleting it
podman start dsh-box                     # bring it back
~~~

`ephemeral` runs one command and drops the container when it exits:

~~~bash
podman run --rm -it --volume "$PWD:/workspace:z" --workdir /workspace \
  ghcr.io/wraindrock/agent-workspace:latest opencode
~~~

## Declarative containers

Everything the wizard does can be written down, which makes a set of containers
reproducible on another machine:

~~~bash
cat > containers.conf <<'EOF'
# name       agent     lifecycle   workspace
review-box   dsh       persistent  ~/work/review
scratch      opencode  ephemeral
EOF

./install.sh --file containers.conf                 # create them
./install.sh --file containers.conf --dry-run       # print the podman commands only
./install.sh --file containers.conf --save saved.conf
~~~

Blank lines and `#` comments are ignored; fields are separated by whitespace and
`mode` and `workspace` may be omitted (defaults: `persistent` and
`~/agent-workspace/<name>`). Use `--file -` to read the declaration from stdin.
`--replace` adopts an existing container with the same name instead of refusing.

For simple cases the flags are enough:

~~~bash
./install.sh --agent opencode --count 2 --name box --workspace "$PWD"
~~~

## Credentials

Each created container gets its own file,
`~/.config/agent-workspace/containers/<name>.env`, written with mode `600` and
passed to podman with `--env-file`. The installer learns the key names from the image
catalog (`AGENT_ENV` in the agent recipe) and takes values from your environment when
they are already exported; `--env KEY=VALUE` adds one explicitly. Nothing is baked into
an image, and the file never lands in the workspace.

## Managing what you created

~~~bash
./install.sh --list             # name, agent, status
./install.sh --verify           # running containers and the agent binary each one can run
./install.sh --remove box       # container, home volume and credential file
~~~

Containers created by the installer are labelled
`agent-workspace.manager=install.sh` together with `agent-workspace.agent` and
`agent-workspace.mode`, so the tool only ever touches its own containers and can tell
you which agent a container was created for.

## Security notes

* Run rootless: the container's root is your user, and anything it writes into
  the bind-mounted workspace stays owned by you.
* Only the workspace directory is mounted, with the `:z` SELinux relabel - not your
  home directory.
* Keep keys in the per-container env file (mode 600) or the environment rather
  than in shell history.
* The image's own `agent-workspace` CLI refuses lifecycle commands inside a
  container: the host owns container lifecycle.

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| `podman is not available` | install podman, or point `PODMAN` at it |
| `container ... already exists` | re-run with `--replace`, or choose another `--name` |
| the image cannot be pulled | `--image <ref>` for a local build, `--no-pull` to fail fast |
| a credential is missing | re-run with `--env KEY=VALUE`, or export it first |
| nothing is listed | `--list` only shows containers this installer created |
