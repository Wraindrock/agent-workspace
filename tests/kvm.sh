#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Behavioral assertions for the KVM backend.
#
# A fake libvirt (`virsh`), QEMU disk tools, cloud-init seed builder, SSH and
# container helper record every command and keep the state the backend reads
# back, so the backend is asserted without booting anything and without /dev/kvm:
# what XML is defined, which kernel/initrd it boots, how the hostfwd entries map
# to the web port, how the SSH channel is built and quoted, how the transfer
# buffers round-trip, and what happens when the image or the host is not ready.
#
# What this file cannot prove is that libvirt/qemu accept these XML and argv
# shapes end to end. That needs KVM hardware; the real boot is documented in
# docs/backend-model.md with the captured serial console (the Phase A proof), and
# the same disk/kernel/root= command line is what the XML emits.
# ---------------------------------------------------------------------------
set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
backend="${repo_root}/installer/lib/backend-kvm.sh"
engine="${repo_root}/installer/lib/engine.sh"
i18n="${repo_root}/installer/lib/i18n.sh"
state="${repo_root}/installer/lib/state.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/aw-kvm-test.XXXXXX")"
trap 'rm -rf -- "$WORK"' EXIT

failures=0
pass() { printf '  ok   %s\n' "$1"; }
fail() { printf '  fail %s\n' "$1"; failures=$((failures + 1)); }

mkdir -p "$WORK/bin" "$WORK/rootfs/boot" "$WORK/rootfs/usr/bin" "$WORK/rootfs/home"
printf 'kernel\n' >"$WORK/rootfs/boot/vmlinuz-7.2.10-200.fc44.x86_64"
printf 'initramfs\n' >"$WORK/rootfs/boot/initramfs-7.2.10-200.fc44.x86_64.img"
printf '#!/bin/sh\n' >"$WORK/rootfs/usr/bin/cloud-init"
chmod +x "$WORK/rootfs/usr/bin/cloud-init"
printf 'note\n' >"$WORK/rootfs/home/note.txt"
: >"$WORK/kvmdev"
export FAKE_KVM_STATE="$WORK/state"
export FAKE_KVM_LOG="$WORK/log"
export FAKE_SSH_LOG="$WORK/ssh-log"
export FAKE_PODMAN_LOG="$WORK/podman-log"
export FAKE_VIRSH_FAIL="${FAKE_VIRSH_FAIL:-0}"
: >"$FAKE_KVM_LOG"; : >"$FAKE_SSH_LOG"; : >"$FAKE_PODMAN_LOG"
mkdir -p "$FAKE_KVM_STATE/domains" "$FAKE_KVM_STATE/running"

# --- fake libvirt ----------------------------------------------------------
cat >"$WORK/bin/virsh" <<'FAKE'
#!/usr/bin/env bash
set -uo pipefail
printf '%s\n' "$*" >>"${FAKE_KVM_LOG:?}"
[[ "${FAKE_VIRSH_FAIL:-0}" == "1" ]] && { echo "error: failed to connect to the hypervisor" >&2; exit 1; }
[[ "${1:-}" == "--connect" ]] && shift 2
cmd="${1:-}"; shift || true
state="${FAKE_KVM_STATE:?}"
case "$cmd" in
  version)  printf 'Using library version 12.0.0\nUsing API version 1.0.0\n' ;;
  dominfo)  [[ -e "$state/domains/${1:-}" ]] ;;
  list)     for f in "$state"/domains/*; do [[ -e "$f" ]] && basename "$f"; done ;;
  define)   name="$(sed -n "s:.*<name>\([^<]*\)</name>.*:\1:p" "${1:-}" | head -n 1)"
            [[ -n "$name" ]] || exit 1
            cp "${1:-}" "$state/domains/$name" ;;
  start)    : >"$state/running/${1:-}" ;;
  domstate) if [[ ! -e "$state/domains/${1:-}" ]]; then exit 1; fi
            if [[ -e "$state/running/${1:-}" ]]; then printf 'running\n'; else printf 'shut off\n'; fi ;;
  shutdown) rm -f "$state/running/${1:-}" ;;
  destroy)  rm -f "$state/running/${1:-}" ;;
  undefine)
    [[ "${1:-}" == "--nvram" ]] && shift
    rm -f "$state/domains/${1:-}" "$state/running/${1:-}" ;;
  console)  pretty="cat"; printf 'fake console\n' ;;
  *)        : ;;
esac
exit 0
FAKE

cat >"$WORK/bin/qemu-img" <<'FAKE'
#!/usr/bin/env bash
printf 'qemu-img %s\n' "$*" >>"${FAKE_KVM_LOG:?}"
[[ "${1:-}" == "convert" ]] || exit 0
for last in "$@"; do :; done
: >"$last"
FAKE

cat >"$WORK/bin/mkfs.ext4" <<'FAKE'
#!/usr/bin/env bash
printf 'mkfs.ext4 %s\n' "$*" >>"${FAKE_KVM_LOG:?}"
for last in "$@"; do :; done
: >"$last"
FAKE

cat >"$WORK/bin/truncate" <<'FAKE'
#!/usr/bin/env bash
printf 'truncate %s\n' "$*" >>"${FAKE_KVM_LOG:?}"
: >"${@: -1}"
FAKE

cat >"$WORK/bin/xorriso" <<'FAKE'
#!/usr/bin/env bash
printf 'xorriso %s\n' "$*" >>"${FAKE_KVM_LOG:?}"
out=""
while [[ $# -gt 0 ]]; do
  [[ "$1" == "-output" ]] && { out="$2"; shift 2; continue; }
  shift
done
[[ -n "$out" ]] && printf 'iso\n' >"$out"
FAKE

cat >"$WORK/bin/ssh-keygen" <<'FAKE'
#!/usr/bin/env bash
printf 'ssh-keygen %s\n' "$*" >>"${FAKE_KVM_LOG:?}"
file=""
while [[ $# -gt 0 ]]; do
  [[ "$1" == "-f" ]] && { file="$2"; shift 2; continue; }
  shift
done
[[ -n "$file" ]] || exit 1
printf 'PRIVATE\n' >"$file"
printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFAKEFAKEFAKEFAKE agent-workspace-fake\n' >"${file}.pub"
FAKE

cat >"$WORK/bin/ssh" <<'FAKE'
#!/usr/bin/env bash
set -uo pipefail
printf '%s\n' "$*" >>"${FAKE_SSH_LOG:?}"
if [[ "$*" == *"tar czf -"* ]]; then
  tar czf - -C "${FAKE_SSH_ROOT:-/nonexistent}" . 2>/dev/null && exit 0
  printf 'fake\n' >/dev/null
  exit 0
fi
if [[ "$*" == *"tar xzf -"* || "$*" == *"tar xzf /"* ]]; then
  cat >/dev/null || true
  exit 0
fi
exit 0
FAKE

cat >"$WORK/bin/unshare" <<'FAKE'
#!/usr/bin/env bash
# Record the argv (the test asserts chown and mkfs share this one user-namespace
# session) and exit 0: the real namespace would let the chown succeed, the fake
# mkfs ignores the tree entirely. `unshare -r true` probes support and the image
# export runs `unshare -r tar ...`; both must really execute.
printf '%s\n' "$*" >>"${FAKE_KVM_LOG:?}"
if [[ " $* " == *" bash -c "* ]]; then
  exit 0
fi
args=()
for a in "$@"; do
  case "$a" in
    -r|--map-root-user) continue ;;
  esac
  args+=("$a")
done
if [[ ${#args[@]} -eq 0 ]]; then
  exit 0
fi
exec "${args[@]}"
FAKE

cat >"$WORK/bin/podman" <<'FAKE'
#!/usr/bin/env bash
set -uo pipefail
printf '%s\n' "$*" >>"${FAKE_PODMAN_LOG:?}"
cmd="${1:-}"; shift || true
case "$cmd" in
  pull|rm)      exit 0 ;;
  image)        printf 'sha256:fakeimage\n' ;;
  create)       printf 'fakecid\n' ;;
  export)       tar cf - -C "${FAKE_IMAGE_ROOTFS:?}" . ;;
  run)          exit 0 ;;
  *)            exit 0 ;;
esac
FAKE

chmod +x "$WORK"/bin/*

rootfs_ok() { printf '%s' "$WORK/rootfs"; }

# run_engine <snippet>: the selection code alone (probe/status/choose).
run_engine() {
  local snippet="$1"
  (
    set -euo pipefail
    export PATH="$WORK/bin:$PATH"
    export AW_KVM_DEVICE="${AW_KVM_DEVICE:-$WORK/kvmdev}"
    export AW_KVM_ROOT="$WORK/vms"
    export DATA_HOME="$WORK/data" CONF_HOME="$WORK/conf"
    export KVM_DEVICE="$AW_KVM_DEVICE" KVM_ROOT="$AW_KVM_ROOT" KVM_URI="qemu:///session"
    die_k() { printf 'die_k: %s\n' "$(tf "$@")" >&2; exit 1; }
    msg_k() { :; }
    ok_k() { :; }
    warn_k() { printf 'warn: %s\n' "$(tf "$@")" >&2; }
    heading_k() { :; }
    # shellcheck source=/dev/null
    source "$i18n"
    # shellcheck source=/dev/null
    source "$engine"
    eval "$snippet"
  )
}

# run_backend <snippet>: the loaded backend under the strict mode the installer
# runs with. ENGINE_BIN is the fake virsh; the state helpers are real.
run_backend() {
  local snippet="$1"
  (
    set -euo pipefail
    export PATH="$WORK/bin:$PATH"
    export ENGINE=kvm ENGINE_BIN="$WORK/bin/virsh"
    export AW_KVM_DEVICE="$WORK/kvmdev"
    export AW_KVM_ROOT="$WORK/vms"
    export DATA_HOME="$WORK/data" CONF_HOME="$WORK/conf"
    export KVM_DEVICE="$AW_KVM_DEVICE" KVM_ROOT="$AW_KVM_ROOT" KVM_URI="qemu:///session"
    export AGENT_USER=agent WEB_CONTAINER_PORT=3080
    export FAKE_IMAGE_ROOTFS="${FAKE_IMAGE_ROOTFS:-$(rootfs_ok)}"
    export FAKE_SSH_ROOT="${FAKE_SSH_ROOT:-$(rootfs_ok)}"
    die_k() { printf 'die_k: %s\n' "$(tf "$@")" >&2; exit 1; }
    msg_k() { :; }
    ok_k() { :; }
    warn_k() { printf 'warn: %s\n' "$(tf "$@")" >&2; }
    heading_k() { :; }
    # shellcheck source=/dev/null
    source "$i18n"
    # shellcheck source=/dev/null
    source "$engine"
    # shellcheck source=/dev/null
    source "$state"
    # shellcheck source=/dev/null
    source "$backend"
    eval "$snippet"
  )
}

log_has()      { grep -qF -- "$1" "$FAKE_KVM_LOG"; }
ssh_log_has()  { grep -qF -- "$1" "$FAKE_SSH_LOG"; }

# --- interface + probe -----------------------------------------------------
echo "interface and probe"
if run_backend 'declare -F eng_create_persistent >/dev/null && declare -F eng_start >/dev/null && declare -F eng_stop >/dev/null && declare -F eng_exec >/dev/null && declare -F eng_exec_root >/dev/null && declare -F eng_volume_archive >/dev/null && declare -F eng_volume_restore_archive >/dev/null && declare -F eng_commit >/dev/null && declare -F eng_host_port >/dev/null' >/dev/null 2>&1; then
  pass "the backend defines the full verb interface"
else
  fail "the KVM backend is missing a verb"
fi

if run_engine 'kvm_probe' >/dev/null 2>&1; then
  pass "the probe passes when /dev/kvm, libvirt and every tool are present"
else
  fail "the probe failed on a fully faked host: ${KVM_PROBE_MISSING:-}"
fi

out="$(AW_KVM_DEVICE="$WORK/missing-kvm" run_engine 'kvm_probe' 2>&1 || true)"
if [[ "$out" != *"${WORK}/missing-kvm"* ]]; then
  # kvm_probe prints nothing; read the global through a second call.
  out="$(AW_KVM_DEVICE="$WORK/missing-kvm" run_engine 'kvm_probe || printf "%s" "$KVM_PROBE_MISSING"' 2>/dev/null)"
fi
if [[ "$out" == *"missing-kvm"* ]]; then
  pass "a missing KVM device is reported by name"
else
  fail "the probe did not name the missing device: '$out'"
fi

out="$(FAKE_VIRSH_FAIL=1 run_engine 'kvm_probe || printf "%s" "$KVM_PROBE_MISSING"' 2>/dev/null)"
if [[ "$out" == *"libvirt is not reachable"* ]]; then
  pass "an unreachable libvirt URI is reported, not just 'not installed'"
else
  fail "the probe hid an unreachable libvirt: '$out'"
fi

if [[ "$(run_engine 'backend_status_key kvm')" == "backend_available" ]]; then
  pass "a ready KVM host shows kvm as available"
else
  fail "backend_status_key said '$(run_engine 'backend_status_key kvm')'"
fi

out="$(FAKE_VIRSH_FAIL=1 run_engine 'resolve_engine kvm' 2>&1 || true)"
if [[ "$out" == *"kvm"* && "$out" == *"libvirt is not reachable"* ]]; then
  pass "selecting kvm on a broken host refuses with the missing item"
else
  fail "resolve_engine did not refuse with an actionable message: '$out'"
fi

if [[ "$(run_engine 'backend_names')" == *kvm* ]]; then
  pass "kvm is listed among the installed backends once virsh is present"
else
  fail "backend_names did not list kvm"
fi

# --- image export ----------------------------------------------------------
echo "image export"
if run_backend 'eng_pull img' >/dev/null 2>&1 && run_backend 'eng_image_exists img' >/dev/null 2>&1; then
  pass "eng_pull exports the OCI rootfs and records it as present"
else
  fail "eng_pull did not produce a usable image cache"
fi
if run_backend 'eng_image_exists img' >/dev/null 2>&1; then
  if run_backend 'eng_pull img' >/dev/null 2>&1; then
    pass "pulling an unchanged image again is a no-op"
  else
    fail "a second eng_pull failed"
  fi
fi
cache="$WORK/vms/images/img"
if [[ -s "$cache/vmlinuz" && -s "$cache/initramfs.img" ]]; then
  pass "the cache carries the kernel and initramfs the domain boots"
else
  fail "the image cache has no kernel/initramfs"
fi

# --- create ----------------------------------------------------------------
echo "create"
run_backend 'eng_create_persistent web1 img aw-web1-home '"$WORK"'/env 18080 agent' >/dev/null 2>&1
created=0
if [[ -f "$WORK/vms/web1/domain.xml" && -f "$WORK/vms/web1/disk.qcow2" && -f "$WORK/vms/web1/seed.iso" ]]; then
  created=1
fi
if grep -q '^-r bash -c' "${FAKE_KVM_LOG:-/dev/null}" && grep -q 'chown -R 0:0' "${FAKE_KVM_LOG:-/dev/null}" && grep -q 'mkfs.ext4' "${FAKE_KVM_LOG:-/dev/null}"; then
  pass "chown and mkfs run in one user-namespace session (ownership is recorded)"
else
  fail "the disk build did not run chown and mkfs in the same user namespace"
fi
if [[ "$created" -eq 1 ]]; then
  pass "create defines a domain, a disk and a cloud-init seed ISO"
else
  fail "create did not produce the domain files"
fi
xml="$WORK/vms/web1/domain.xml"
if grep -q '<kernel>' "$xml" && grep -q 'root=/dev/vda rw console=ttyS0' "$xml" && grep -q 'vda' "$xml"; then
  pass "the domain boots the direct-kernel path (kernel + initrd + root=/dev/vda)"
else
  fail "the domain XML does not boot the proven direct-kernel path"
fi
if grep -q "hostfwd=tcp:127.0.0.1:18080-:3080" "$xml" 2>/dev/null || grep -q 'hostfwd=tcp:127.0.0.1:' "$xml"; then
  pass "the domain publishes the web port over user-mode hostfwd"
else
  fail "no hostfwd for the web port in the domain XML"
fi
devices_line="$(grep -n '</devices>' "$xml" | cut -d: -f1 || true)"
cmdline_line="$(grep -n '<qemu:commandline>' "$xml" | cut -d: -f1 || true)"
if [[ -n "$devices_line" && -n "$cmdline_line" && "$cmdline_line" -gt "$devices_line" ]]; then
  pass "qemu:commandline is a child of domain (libvirt drops it inside devices)"
else
  fail "qemu:commandline is in the wrong place; libvirt would boot without a NIC"
fi
if grep -q 'virtio-net-pci,netdev=net0,bus=pcie.0,addr=0x6' "$xml"; then
  pass "the custom NIC has an explicit PCI slot (QEMU otherwise collides with slot 1)"
else
  fail "the custom NIC has no explicit PCI slot; QEMU would fail to start the domain"
fi
if [[ "$(stat -c %a "$WORK/vms/web1/id_ed25519")" == "600" ]]; then
  pass "the per-instance SSH key is mode 0600"
else
  fail "the SSH key is not 0600"
fi
if grep -Fq 'for _ in $(seq 1 15); do' "$WORK/vms/web1/seed/user-data"; then
  pass "the seed keeps shell substitutions literal (an unquoted heredoc would break the YAML)"
else
  fail "shell substitution expanded inside the cloud-init user-data, which breaks its YAML"
fi
if grep -q 'ssh_authorized_keys' "$WORK/vms/web1/seed/user-data" && grep -q 'name: agent' "$WORK/vms/web1/seed/user-data"; then
  pass "the seed injects the agent user and the key"
else
  fail "the seed does not create the agent user with a key"
fi
if grep -q 'autologin root' "$WORK/vms/web1/seed/user-data"; then
  pass "the seed enables serial-getty autologin root for rescue"
else
  fail "the serial console has no root autologin"
fi

# --- hostfwd mapping -------------------------------------------------------
echo "presentation channel"
ssh_port="$(sed -n '1p' "$WORK/vms/web1/ssh-port")"
if [[ "$(run_backend 'eng_host_port web1 3080')" == "127.0.0.1:18080" ]]; then
  pass "guest :3080 maps to the loopback hostfwd port"
else
  fail "eng_host_port web1 3080 said '$(run_backend 'eng_host_port web1 3080')'"
fi
if [[ "$(run_backend 'eng_host_port web1 22')" == "127.0.0.1:${ssh_port}" ]]; then
  pass "guest SSH maps to its own loopback forward"
else
  fail "eng_host_port web1 22 said '$(run_backend 'eng_host_port web1 22')'"
fi
if [[ -z "$(run_backend 'eng_host_port web1 4000')" ]]; then
  pass "an unpublished port has no host mapping"
else
  fail "eng_host_port published a port it never forwarded"
fi

# --- exec ------------------------------------------------------------------
echo "exec"
run_backend 'eng_exec web1 echo hello' >/dev/null 2>&1
if ssh_log_has "agent@127.0.0.1" && ssh_log_has "-p ${ssh_port}" && ssh_log_has "bash -lc"; then
  pass "enter/exec SSHes as the agent user on the per-instance port"
else
  fail "the exec command did not use the expected SSH channel"
fi
if ssh_log_has "echo" && ssh_log_has "hello"; then
  pass "the command is passed through the remote login shell"
else
  fail "the command did not reach the remote argv"
fi

# --- lifecycle -------------------------------------------------------------
echo "lifecycle"
if run_backend 'eng_stop web1' >/dev/null 2>&1 && [[ ! -e "$FAKE_KVM_STATE/running/web1" ]]; then
  pass "stop shuts the domain down"
else
  fail "eng_stop did not stop the domain"
fi
run_backend 'eng_start web1' >/dev/null 2>&1
if run_backend 'eng_container_running web1' >/dev/null 2>&1; then
  pass "start brings the domain back to running"
else
  fail "eng_start did not run the domain"
fi
printf 'boot line\nfedora login:\n' >"$WORK/vms/web1/console.log"
if run_backend 'eng_logs web1 5 0' 2>/dev/null | grep -q 'fedora login:'; then
  pass "logs shows the serial console"
else
  fail "eng_logs did not show the console log"
fi

# --- transfer buffers ------------------------------------------------------
echo "transfer buffers"
state_set web1 VOLUME aw-web1-home ENGINE kvm AGENT agent >/dev/null 2>&1 || true
if run_backend 'state_set web1 VOLUME aw-web1-home' >/dev/null 2>&1 && run_backend 'eng_volume_exists aw-web1-home' >/dev/null 2>&1; then
  pass "a volume resolves to the instance that owns the live home"
else
  fail "eng_volume_exists could not resolve the volume"
fi
mkdir -p "$WORK/arch"
if run_backend 'eng_volume_archive aw-web1-home '"$WORK"'/arch img' >/dev/null 2>&1 && tar tzf "$WORK/arch/home.tar.gz" | grep -q './note.txt'; then
  pass "backup archives the guest home over SSH, nothing is bind-mounted"
else
  fail "eng_volume_archive did not stream the home over SSH"
fi
if run_backend 'eng_volume_restore_archive aw-web1-home '"$WORK"'/arch/home.tar.gz img' >/dev/null 2>&1; then
  if ssh_log_has "tar xzf -"; then
    pass "restore streams the archive back into the guest home"
  else
    fail "restore did not use the SSH channel"
  fi
else
  fail "eng_volume_restore_archive failed"
fi
if run_backend 'eng_volume_clone aw-web1-home aw-copy-home img' >/dev/null 2>&1 && [[ -s "$WORK/vms/volumes/aw-copy-home/home.tar.gz" ]]; then
  pass "clone keeps a transfer archive for fork/rollback"
else
  fail "eng_volume_clone did not stage the archive"
fi

# --- commit ----------------------------------------------------------------
echo "snapshot"
if run_backend 'eng_commit web1 snap1' >/dev/null 2>&1 && [[ -f "$WORK/vms/images/snap1.qcow2" ]]; then
  pass "commit freezes the disk into a qcow2 that create can boot from"
else
  fail "eng_commit did not write the qcow2"
fi
if log_has "qemu-img convert"; then
  pass "commit uses qemu-img, not a host-side copy of the guest files"
else
  fail "commit did not run qemu-img"
fi

# --- refusals --------------------------------------------------------------
echo "refusals"
bad_rootfs="$WORK/no-cloudinit"
mkdir -p "$bad_rootfs/boot" "$bad_rootfs/usr/bin"
printf 'k\n' >"$bad_rootfs/boot/vmlinuz-7.2.10-200.fc44.x86_64"
printf 'i\n' >"$bad_rootfs/boot/initramfs-7.2.10-200.fc44.x86_64.img"
out="$(FAKE_IMAGE_ROOTFS="$bad_rootfs" run_backend 'eng_pull badimg' 2>&1 || true)"
if [[ "$out" == *"cloud-init"* ]]; then
  pass "an image without cloud-init is refused with the reason (the seed could not be injected)"
else
  fail "pulling a cloud-init-less image did not explain the refusal: '$out'"
fi
out="$(run_backend 'eng_create_ephemeral eph' 2>&1 || true)"
if [[ "$out" == *"ephemeral"* ]]; then
  pass "ephemeral mode is refused for VMs, with the reason"
else
  fail "eng_create_ephemeral did not refuse: '$out'"
fi

echo
if [[ "$failures" -eq 0 ]]; then
  echo "kvm: all checks passed"
  exit 0
fi
echo "kvm: ${failures} check(s) failed"
exit 1
