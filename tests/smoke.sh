#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Container self test: boots the built image as a plain container and checks
# the promises the image makes, without needing a booted system.
#
#   tests/smoke.sh ghcr.io/wraindrock/agent-workspace:latest
#   tests/smoke.sh localhost/agent-workspace:dev
# ---------------------------------------------------------------------------
set -euo pipefail

IMAGE="${1:-}"
[[ -n "$IMAGE" ]] || { echo "usage: tests/smoke.sh <image ref>" >&2; exit 2; }

command -v podman >/dev/null 2>&1 || { echo "podman is required" >&2; exit 1; }

failures=0
pass() { printf '  ok   %s\n' "$1"; }
fail() { printf '  fail %s\n' "$1"; failures=$((failures + 1)); }

in_image() {
  podman run --rm --entrypoint "$1" "$IMAGE" "${@:2}"
}

echo "smoke test: ${IMAGE}"

# The image has to name its own PID 1. `podman run --systemd=always` does not
# replace an image command (checked on podman 5.8.4), so a container started
# without this would inherit the base image's /usr/bin/bash, exit immediately
# and never boot - which is what install.sh used to create.
image_cmd="$(podman image inspect "$IMAGE" --format '{{.Config.Cmd}}' 2>/dev/null || true)"
if [[ "$image_cmd" == "[/sbin/init]" ]]; then
  pass "image command is /sbin/init"
else
  fail "image command is [${image_cmd:-empty}], want [/sbin/init]"
fi

if in_image /usr/bin/agent-workspace version >/dev/null; then
  pass "agent-workspace version"
else
  fail "agent-workspace version"
fi

if in_image /usr/bin/agent-workspace manifest --json | jq -e '.modules | length > 0' >/dev/null 2>&1; then
  pass "manifest declares at least one module"
else
  fail "manifest is missing or empty"
fi

if in_image /usr/bin/agent-workspace doctor --offline --strict --quiet >/dev/null 2>&1; then
  pass "doctor --offline --strict"
else
  fail "doctor --offline --strict"
fi

for binary in podman git node npm python3 gh jq curl tmux nvim rg; do
  if in_image /bin/bash -c "command -v ${binary} >/dev/null"; then
    pass "binary ${binary}"
  else
    fail "binary ${binary}"
  fi
done

# The image publishes the agents it ships; every binary in that catalog has to
# be runnable, otherwise install.sh would offer an agent the image cannot start.
catalog="$(in_image /usr/bin/agent-workspace manifest --json 2>/dev/null | jq -r '(.agentCatalog // {}) | to_entries[] | .value.binaries[]' 2>/dev/null || true)"
if [[ -z "$catalog" ]]; then
  fail "manifest declares no agent catalog"
else
  for binary in $catalog; do
    if in_image /bin/bash -c "command -v ${binary} >/dev/null"; then
      pass "agent binary ${binary}"
    else
      fail "agent binary ${binary}"
    fi
  done
fi

for unit in /etc/systemd/system/agent-workspace-firstboot.service \
            /usr/lib/systemd/system/agent-workspace-health.timer \
            /etc/sysctl.d/90-agent-workspace.conf; do
  if in_image /usr/bin/test -r "$unit"; then
    pass "${unit}"
  else
    fail "${unit}"
  fi
done

# The ostree symlinks /home, /opt, /usr/local and /root have to resolve in the
# image: installers write through them during the build, a dangling /opt made
# `pipx ensurepath --global` fail on every build (and the opt-in aider recipe
# abort the build outright), and a dangling /home breaks container creation -
# the engine has to create the mount point of the agent home volume and reports
# `crun: creating '/home/agent': openat2 'home': No such file or directory`.
for dir in /home /opt /usr/local /root; do
  if in_image /usr/bin/test -e "$dir"; then
    pass "${dir} resolves"
  else
    fail "${dir} is a dangling symlink"
  fi
done

# install.sh mounts the agent's home volume at /home/<user>; the engine creates
# that directory inside the container, so the parent has to be usable.
if in_image /bin/bash -c 'install -d -m 0755 /home/agent && test -d /home/agent'; then
  pass "the agent home mount point can be created"
else
  fail "the agent home mount point /home/agent cannot be created"
fi

if in_image /bin/bash -c 'python3 -m pipx ensurepath --global' >/dev/null 2>&1; then
  pass "pipx ensurepath --global"
else
  fail "pipx ensurepath --global"
fi

# npm installs during the build keep their debug logs next to the npm cache,
# which 90-cleanup removes. Logs left in root's home would ship in the image and
# show up as a `bootc container lint` warning.
if in_image /bin/bash -c '[[ ! -e /var/roothome/.npm/_logs ]]'; then
  pass "no npm debug logs in root's home"
else
  fail "npm left debug logs in root's home"
fi

echo
if [[ "$failures" -eq 0 ]]; then
  echo "smoke: all checks passed"
else
  echo "smoke: ${failures} check(s) failed"
  exit 1
fi
