#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# The KVM backend: an instance is a libvirt domain booting a disk image that
# carries this project's own OCI rootfs.
#
# How the pieces fit (docs/backend-model.md, "KVM: the full-system backend"):
#
#   * The OCI image is not bootable by itself: `podman export` gives a rootfs
#     with a kernel and initramfs but no bootloader. The backend therefore
#     builds a disk by copying that rootfs into an ext4 image and boots the
#     kernel directly (`<os><kernel>`/`<initrd>` in the domain XML), exactly the
#     path Phase A proved on a real host (docs/backend-model.md has the console
#     excerpt and the command).
#   * Seeding is cloud-init (NoCloud): a per-instance seed ISO with the agent
#     user, the SSH keys and the serial-getty autologin used by `rescue`. The
#     image has to carry cloud-init; eng_pull refuses an image without it with
#     the rebuild command rather than booting to a login nobody can reach.
#   * The live home is inside the qcow2. There is no host bind mount. Host-side
#     "volumes" are transfer buffers only: backup/restore/fork stream a
#     tar.gz through SSH into a directory, and the VM's disk is the truth.
#   * Management after creation goes through two SSH channels that share one
#     host key pair (0600, per instance): `agent` for `enter` and the agent's
#     own commands, `root` for the administrative verbs (the root toggle, the
#     readiness probes, archive/restore). The key is the only credential, and
#     the SSH ports are user-mode hostfwd entries bound to 127.0.0.1.
#   * `rescue` is the serial console: ttyS0 autologins root, so a broken sshd,
#     sudoers or network still leaves a way in. The console is also the log
#     `install.sh logs` shows, written to the instance directory.
#
# Everything here is testable with fakes: virsh, qemu-img, mkfs.ext4, xorriso,
# ssh and ssh-keygen are always called as separate argv, never through a shell
# pipeline, so tests/kvm.sh can assert exactly what was requested.
# ---------------------------------------------------------------------------

: "${ENGINE_BIN:?the KVM backend needs ENGINE_BIN (virsh)}"

KVM_URI="${KVM_URI:-${AW_KVM_URI:-qemu:///session}}"
KVM_ROOT="${KVM_ROOT:-${AW_KVM_ROOT:-${DATA_HOME}/vms}}"
KVM_MEMORY="${AW_KVM_MEMORY:-4096}"
KVM_VCPUS="${AW_KVM_VCPUS:-2}"
KVM_READY_TIMEOUT="${KVM_READY_TIMEOUT:-180}"
KVM_PROVISION_TIMEOUT="${KVM_PROVISION_TIMEOUT:-300}"
KVM_STOP_TIMEOUT="${KVM_STOP_TIMEOUT:-60}"
KVM_PROVISIONED_MARKER="/var/lib/agent-workspace/.provisioned"

# Every path the backend writes lives under one directory per instance. The
# layout is deliberately readable, because `rescue` documents it:
#   disk.qcow2  seed.iso  console.log  id_ed25519[.pub]  ssh-port  web-port
_kvm_dir() { printf '%s/%s' "${KVM_ROOT}" "${1}"; }
_kvm_key() { printf '%s' "${1}" | sed 's/[^A-Za-z0-9_.-]/_/g'; }
_kvm_image_dir() { printf '%s/images/%s' "${KVM_ROOT}" "$(_kvm_key "${1}")"; }
_kvm_commit_file() { printf '%s/images/%s.qcow2' "${KVM_ROOT}" "$(_kvm_key "${1}")"; }
_kvm_volume_dir() { printf '%s/volumes/%s' "${KVM_ROOT}" "${1}"; }

_kvm_virsh() { "${ENGINE_BIN}" --connect "${KVM_URI}" "$@"; }

# _kvm_remote_cmd ARG... quotes an argv for the remote login shell. ssh joins
# its command words with spaces, so passing them unquoted would turn
# `/bin/bash -c "exec 3<>/dev/tcp/..."` into a completely different command.
_kvm_remote_cmd() {
  local word out=""
  for word in "$@"; do
    out+="$(printf '%q ' "${word}")"
  done
  printf '%s' "${out% }"
}

# _kvm_instance_of_volume VOLUME prints the instance whose live home backs the
# volume, or nothing. The state file is the mapping; the host-side volume
# directory is only a transfer buffer (see the header).
_kvm_instance_of_volume() {
  local volume="${1:-}" name
  [[ -n "${volume}" ]] || return 0
  while IFS= read -r name; do
    [[ -n "${name}" ]] || continue
    if [[ "$(state_get "${name}" VOLUME)" == "${volume}" ]]; then
      printf '%s' "${name}"
      return 0
    fi
  done < <(state_list)
  return 0
}

_kvm_ssh_port() {
  local port=""
  port="$(sed -n '1p' "$(_kvm_dir "${1}")/ssh-port" 2>/dev/null || true)"
  printf '%s' "${port}"
}

_kvm_web_port() {
  local port=""
  port="$(sed -n '1p' "$(_kvm_dir "${1}")/web-port" 2>/dev/null || true)"
  printf '%s' "${port}"
}

# _kvm_ssh NAME USER [args...] runs one command over the instance's key.
_kvm_ssh() {
  local name="$1" user="$2" port
  shift 2
  port="$(_kvm_ssh_port "${name}")"
  ssh -i "$(_kvm_dir "${name}")/id_ed25519" -p "${port:-22}" \
    -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5 \
    "${user}@127.0.0.1" "$@"
}

# _kvm_free_port BASE: first port nothing listens on. The hostfwd entries bind
# 127.0.0.1 only, so this is the same collision check a container publish needs.
_kvm_free_port() {
  local base="${1:-22022}" used candidate i
  if ! command -v ss >/dev/null 2>&1; then
    printf '%s' "${base}"
    return 0
  fi
  used="$(ss -H -ltn 2>/dev/null | awk '{print $4}' | sed -n 's/.*:\([0-9][0-9]*\)$/\1/p' || true)"
  for ((i = 0; i < 200; i++)); do
    candidate=$((base + i))
    if ! grep -qx "${candidate}" <<<"${used}"; then
      printf '%s' "${candidate}"
      return 0
    fi
  done
  printf '%s' "${base}"
}

_kvm_domain_state() {
  _kvm_virsh domstate "${1}" 2>/dev/null | head -n 1 || true
}

_kvm_wait_domain_running() {
  local name="$1" timeout="${2:-60}" waited=0 state=""
  while :; do
    state="$(_kvm_domain_state "${name}")"
    [[ "${state}" == "running" ]] && return 0
    [[ "${waited}" -ge "${timeout}" ]] && return 1
    sleep 1
    waited=$((waited + 1))
  done
}

_kvm_wait_ssh() {
  local name="$1" timeout="${2:-${KVM_READY_TIMEOUT}}" waited=0
  while :; do
    if _kvm_ssh "${name}" root true >/dev/null 2>&1; then
      return 0
    fi
    [[ "${waited}" -ge "${timeout}" ]] && return 1
    sleep 2
    waited=$((waited + 2))
  done
}

_kvm_wait_provisioned() {
  local name="$1" timeout="${2:-${KVM_PROVISION_TIMEOUT}}" waited=0
  while :; do
    if _kvm_ssh "${name}" root test -f "${KVM_PROVISIONED_MARKER}" >/dev/null 2>&1; then
      return 0
    fi
    [[ "${waited}" -ge "${timeout}" ]] && return 1
    sleep 2
    waited=$((waited + 2))
  done
}

# _kvm_console_tail NAME: the last lines the serial console wrote. Used in the
# timeout errors, because a boot that never answers leaves its reason there.
_kvm_console_tail() {
  local file
  file="$(_kvm_dir "${1}")/console.log"
  [[ -f "${file}" ]] || return 0
  tail -n 20 "${file}" 2>/dev/null || true
}

# --- container-helper (for the OCI side) -----------------------------------

# The OCI image has to be exported by a container CLI; the KVM backend itself
# drives libvirt. Pulling through podman is not a hidden second backend: it is
# the image transport named in the header, and the error says so when absent.
_kvm_helper() {
  local bin
  for bin in podman docker; do
    if command -v "${bin}" >/dev/null 2>&1; then
      printf '%s' "${bin}"
      return 0
    fi
  done
  die_k err_kvm_helper
}

# --- the OCI image -> a bootable cache -------------------------------------

_kvm_image_ready() {
  local dir
  dir="$(_kvm_image_dir "${1}")"
  [[ -f "${dir}/.ready" && -d "${dir}/rootfs" && -s "${dir}/vmlinuz" && -s "${dir}/initramfs.img" ]]
}

_kvm_image_current() {
  local image="$1" dir helper id cached
  dir="$(_kvm_image_dir "${image}")"
  [[ -f "${dir}/.ready" ]] || return 1
  helper="$(_kvm_helper 2>/dev/null)" || return 0
  id="$("${helper}" image inspect --format '{{.Id}}' "${image}" 2>/dev/null || true)"
  [[ -n "${id}" ]] || return 0
  cached="$(sed -n '1p' "${dir}/.image-id" 2>/dev/null || true)"
  [[ -z "${cached}" || "${cached}" == "${id}" ]]
}

eng_image_exists() {
  local image="$1"
  if [[ -f "$(_kvm_commit_file "${image}")" ]]; then
    return 0
  fi
  _kvm_image_ready "${image}" || return 1
  _kvm_image_current "${image}"
}

# eng_pull REF exports REF's rootfs once, checks the one thing the seed needs
# (cloud-init), and records the kernel/initramfs the domain boots. Re-running it
# for an unchanged image is cheap; a moved tag re-exports.
eng_pull() {
  local ref="$1" helper dir tmp cid id version
  if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
    printf 'dry-run: %s create/export %s -> %s\n' "$(_kvm_helper)" "${ref}" "$(_kvm_image_dir "${ref}")"
    return 0
  fi
  helper="$(_kvm_helper)"
  dir="$(_kvm_image_dir "${ref}")"
  install -d -m 0700 "${KVM_ROOT}/images"
  if _kvm_image_ready "${ref}" && _kvm_image_current "${ref}"; then
    return 0
  fi
  msg_k kvm_pulling "${ref}"
  "${helper}" pull --quiet "${ref}" >/dev/null 2>&1 || true
  id="$("${helper}" image inspect --format '{{.Id}}' "${ref}" 2>/dev/null || true)"

  tmp="$(mktemp -d "${KVM_ROOT}/images/.pull.XXXXXX")"
  install -d -m 0755 "${tmp}/rootfs"
  cid="$("${helper}" create "${ref}")" || {
    rm -rf "${tmp}"
    die_k err_kvm_pull_failed "${ref}"
  }
  # Extract inside an unprivileged user namespace: as namespace root tar can
  # restore the setuid/setgid bits, so sudo, passwd and friends keep working in
  # the guest. A plain user extraction silently strips them to 0755.
  if ! unshare -r true >/dev/null 2>&1; then
    "${helper}" rm -f "${cid}" >/dev/null 2>&1 || true
    rm -rf "${tmp}"
    die_k err_kvm_no_userns
  fi
  if ! "${helper}" export "${cid}" | unshare -r tar --no-same-owner -xf - -C "${tmp}/rootfs"; then
    "${helper}" rm -f "${cid}" >/dev/null 2>&1 || true
    rm -rf "${tmp}"
    die_k err_kvm_pull_failed "${ref}"
  fi
  "${helper}" rm -f "${cid}" >/dev/null 2>&1 || true

  if [[ ! -x "${tmp}/rootfs/usr/bin/cloud-init" ]]; then
    rm -rf "${tmp}"
    die_k err_kvm_no_cloudinit "${ref}"
  fi

  # Pick the kernel and its matching initramfs. A bootc image keeps them under
  # /usr/lib/modules/<version>/{vmlinuz,initramfs.img} (its /boot is filled by
  # the bootloader install, which a container export never runs); older layouts
  # put vmlinuz-<version> in /boot. Accept both, newest version wins.
  version="$(
    { find "${tmp}/rootfs/usr/lib/modules" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null || true
      find "${tmp}/rootfs/boot" -maxdepth 1 -type f -name 'vmlinuz-*' -printf '%f\n' 2>/dev/null \
        | sed 's/^vmlinuz-//' || true
    } | sort -V | tail -n 1 || true
  )"
  if [[ -z "${version}" ]]; then
    rm -rf "${tmp}"
    die_k err_kvm_no_kernel "${ref}"
  fi
  if [[ -f "${tmp}/rootfs/usr/lib/modules/${version}/vmlinuz" ]]; then
    cp -f "${tmp}/rootfs/usr/lib/modules/${version}/vmlinuz" "${tmp}/vmlinuz"
  else
    cp -f "${tmp}/rootfs/boot/vmlinuz-${version}" "${tmp}/vmlinuz"
  fi
  if [[ -f "${tmp}/rootfs/usr/lib/modules/${version}/initramfs.img" ]]; then
    cp -f "${tmp}/rootfs/usr/lib/modules/${version}/initramfs.img" "${tmp}/initramfs.img"
  elif [[ -f "${tmp}/rootfs/boot/initramfs-${version}.img" ]]; then
    cp -f "${tmp}/rootfs/boot/initramfs-${version}.img" "${tmp}/initramfs.img"
  else
    rm -rf "${tmp}"
    die_k err_kvm_no_kernel "${ref}"
  fi
  printf '%s\n' "${id}" >"${tmp}/.image-id"
  date -u +%Y-%m-%dT%H:%M:%SZ >"${tmp}/.created"
  : >"${tmp}/.ready"

  rm -rf "${dir}"
  mv "${tmp}" "${dir}"
}

eng_image_id() {
  local image="$1" dir
  dir="$(_kvm_image_dir "${image}")"
  if [[ -f "$(_kvm_commit_file "${image}")" ]]; then
    sed -n '1p' "${dir}/.image-id" 2>/dev/null || printf 'qcow2'
    return 0
  fi
  sed -n '1p' "${dir}/.image-id" 2>/dev/null || true
}

eng_image_created() {
  local image="$1" dir
  dir="$(_kvm_image_dir "${image}")"
  if [[ -f "$(_kvm_commit_file "${image}")" ]]; then
    date -u -r "$(_kvm_commit_file "${image}")" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true
    return 0
  fi
  sed -n '1p' "${dir}/.created" 2>/dev/null || true
}

eng_image_remove() {
  local image="$1"
  rm -f "$(_kvm_commit_file "${image}")"
  rm -rf "$(_kvm_image_dir "${image}")"
}

eng_image_run() {
  local image="$1" helper
  shift
  helper="$(_kvm_helper)"
  "${helper}" run --rm --entrypoint "$1" "${image}" "${@:2}"
}

eng_version() {
  local line=""
  line="$(_kvm_virsh version 2>/dev/null | sed -n 's/^Using library version /libvirt /p' | head -n 1 || true)"
  printf '%s' "${line:-libvirt}"
}

# --- domain lifecycle ------------------------------------------------------

eng_container_exists() { _kvm_virsh dominfo "$1" >/dev/null 2>&1; }

eng_container_running() { [[ "$(_kvm_domain_state "$1")" == "running" ]]; }

eng_container_status() {
  local state
  state="$(_kvm_domain_state "$1")"
  printf '%s' "${state:-missing}"
}

eng_container_image() { state_get "$1" RUN_IMAGE; }

eng_labeled_containers() {
  local name
  while IFS= read -r name; do
    [[ -n "${name}" ]] || continue
    [[ -d "$(_kvm_dir "${name}")" ]] && printf '%s\n' "${name}"
  done < <(_kvm_virsh list --all --name 2>/dev/null || true)
  return 0
}

# eng_host_port NAME PORT maps the guest port to the loopback forward. Only the
# web port and SSH are published; anything else has to go through an SSH tunnel,
# which is the documented rule (README, "Presentation channel").
eng_host_port() {
  local name="$1" port="$2" mapped=""
  if [[ "${port}" == "${WEB_CONTAINER_PORT:-3080}" ]]; then
    mapped="$(_kvm_web_port "${name}")"
  elif [[ "${port}" == "22" ]]; then
    mapped="$(_kvm_ssh_port "${name}")"
  fi
  [[ -n "${mapped}" ]] && printf '127.0.0.1:%s' "${mapped}"
  return 0
}

_kvm_domain_xml() {
  local name="$1" disk="$2" seed="$3" console="$4" kernel="$5" initrd="$6" ssh_port="$7" web_port="$8"
  local forward="hostfwd=tcp:127.0.0.1:${ssh_port}-:22"
  if [[ -n "${web_port}" ]]; then
    forward+=",hostfwd=tcp:127.0.0.1:${web_port}-:${WEB_CONTAINER_PORT:-3080}"
  fi
  cat <<XML
<domain type='kvm' xmlns:qemu='http://libvirt.org/schemas/domain/qemu/1.0'>
  <name>${name}</name>
  <memory unit='MiB'>${KVM_MEMORY}</memory>
  <vcpu>${KVM_VCPUS}</vcpu>
  <os>
    <type arch='x86_64' machine='q35'>hvm</type>
    <kernel>${kernel}</kernel>
    <initrd>${initrd}</initrd>
    <cmdline>root=/dev/vda rw console=ttyS0,115200 selinux=0 enforcing=0</cmdline>
  </os>
  <features><acpi/><apic/></features>
  <cpu mode='host-passthrough' check='none'/>
  <clock offset='utc'/>
  <on_poweroff>destroy</on_poweroff>
  <on_reboot>restart</on_reboot>
  <on_crash>destroy</on_crash>
  <devices>
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2' cache='none' io='native'/>
      <source file='${disk}'/>
      <target dev='vda' bus='virtio'/>
    </disk>
    <disk type='file' device='disk'>
      <driver name='qemu' type='raw'/>
      <source file='${seed}'/>
      <target dev='vdb' bus='virtio'/>
      <readonly/>
    </disk>
    <serial type='file'>
      <source path='${console}'/>
      <target port='0'/>
    </serial>
    <console type='file'>
      <source path='${console}'/>
      <target type='serial' port='0'/>
    </console>
    <memballoon model='virtio'/>
  </devices>
  <!-- qemu:commandline is a child of <domain>, not of <devices>; inside
       <devices> libvirt silently drops it and the domain boots with no NIC. The
       NIC also needs an explicit PCI slot: QEMU otherwise puts it on slot 1,
       which libvirt has already given to its first PCIe root port, and the
       domain refuses to start ("PCI: slot 1 function 0 not available"). -->
  <qemu:commandline>
    <qemu:arg value='-netdev'/>
    <qemu:arg value='user,id=net0,${forward}'/>
    <qemu:arg value='-device'/>
    <qemu:arg value='virtio-net-pci,netdev=net0,bus=pcie.0,addr=0x6'/>
  </qemu:commandline>
</domain>
XML
}

_kvm_seed() {
  local name="$1" dir="$2" public_key="$3" instance_id
  instance_id="iid-${name}-$(date -u +%Y%m%dT%H%M%SZ)"
  install -d -m 0700 "${dir}/seed"
  cat >"${dir}/seed/meta-data" <<META
instance-id: ${instance_id}
local-hostname: ${name}
META
  cat >"${dir}/seed/user-data" <<USERDATA
#cloud-config
hostname: ${name}
preserve_hostname: false
disable_root: false
ssh_pwauth: false
users:
  - name: root
    ssh_authorized_keys:
      - ${public_key}
  - name: agent
    uid: 1000
    shell: /bin/bash
    groups: [wheel]
    lock_passwd: true
    ssh_authorized_keys:
      - ${public_key}
write_files:
  - path: /etc/ssh/sshd_config.d/60-agent-workspace.conf
    permissions: '0644'
    content: |
      PermitRootLogin prohibit-password
      PubkeyAuthentication yes
      PasswordAuthentication no
  - path: /etc/systemd/system/serial-getty@ttyS0.service.d/autologin.conf
    permissions: '0644'
    content: |
      [Service]
      ExecStart=
      ExecStart=-/sbin/agetty --autologin root --noclear %I \$TERM
  - path: /usr/local/sbin/aw-open-presentation
    permissions: '0755'
    content: |
      #!/bin/bash
      # Presentation channel. user-mode networking makes the guest see the host
      # as 10.0.2.0/24 and every published port arrives from that gateway, so only
      # that source range may reach the instance web port. Host loopback is the
      # only place the forward is exposed.
      command -v firewall-cmd >/dev/null 2>&1 || exit 0
      systemctl is-active --quiet firewalld || systemctl start firewalld || exit 0
      for _ in \$(seq 1 15); do
        firewall-cmd --permanent --add-rich-rule='rule family=ipv4 source address=10.0.2.0/24 port port=3080 protocol=tcp accept' >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 && exit 0
        sleep 1
      done
      exit 0
runcmd:
  - [ systemctl, daemon-reload ]
  - [ systemctl, enable, --now, sshd.service ]
  - [ /usr/local/sbin/aw-open-presentation ]
  - [ systemctl, restart, serial-getty@ttyS0.service ]
USERDATA
  xorriso -as mkisofs -quiet -V cidata -joliet -rock \
    -output "${dir}/seed.iso" "${dir}/seed" >/dev/null 2>&1 \
    || die_k err_kvm_seed_failed "${name}"
  [[ -s "${dir}/seed.iso" ]] || die_k err_kvm_seed_failed "${name}"
}

_kvm_build_disk() {
  local name="$1" image="$2" disk="$3" commit cache rootfs raw bytes blocks log
  commit="$(_kvm_commit_file "${image}")"
  if [[ -f "${commit}" ]]; then
    qemu-img convert -O qcow2 "${commit}" "${disk}" >/dev/null \
      || die_k err_kvm_disk_failed "${name}"
    return 0
  fi
  cache="$(_kvm_image_dir "${image}")"
  _kvm_image_ready "${image}" || die_k err_kvm_image_missing "${image}"
  rootfs="${cache}/rootfs"
  # 25% slack for ext4 metadata plus one gigabyte for first boot, rounded up to
  # a whole MiB. mkfs.ext4 -d copies the tree, so the image is self-contained.
  # Hardlinks are copied once per path by mkfs.ext4 -d, so count every link:
  # the export normally has none, but a staged/unpacked tree may (du -sb alone
  # counts a hardlinked inode once and the filesystem then runs out of blocks).
  bytes="$(du -sb --count-links "${rootfs}" 2>/dev/null | cut -f1)"
  [[ -n "${bytes}" ]] || bytes="$(du -sb "${rootfs}" 2>/dev/null | cut -f1)"
  bytes="${bytes:-0}"
  blocks=$(( (bytes + bytes / 4 + 1073741824 + 1048575) / 1048576 * 256 ))
  raw="${disk}.raw"
  log="${raw}.log"
  msg_k kvm_building_disk "${name}" "${image}"
  truncate -s "$((blocks * 4096))" "${raw}"
  # The tree is extracted as the invoking user and contains root-only modes
  # (e.g. /etc/gshadow is 0000), so mkfs must read those files *and* record
  # root ownership. Both happen as uid 0 inside an unprivileged user namespace:
  # `unshare -r` needs no daemon, and podman/docker's `unshare` is the fallback.
  # fakeroot is deliberately not used: it fakes chown/stat but cannot grant the
  # DAC override a 0000 file needs, so mkfs would fail on "gshadow".
  if command -v unshare >/dev/null 2>&1 && unshare -r true >/dev/null 2>&1; then
    if ! unshare -r bash -c 'chown -R 0:0 "$1" && mkfs.ext4 -q -F -L agent-workspace -b 4096 -d "$1" "$2" "$3"' \
      _ "${rootfs}" "${raw}" "${blocks}" >/dev/null 2>"${log}"; then
      die_k err_kvm_disk_failed "${name}" "${log}"
    fi
  elif ! "$(_kvm_helper)" unshare bash -c 'chown -R 0:0 "$1" && mkfs.ext4 -q -F -L agent-workspace -b 4096 -d "$1" "$2" "$3"' \
    _ "${rootfs}" "${raw}" "${blocks}" >/dev/null 2>"${log}"; then
    die_k err_kvm_disk_failed "${name}" "${log}"
  fi
  if ! qemu-img convert -f raw -O qcow2 "${raw}" "${disk}" >/dev/null 2>"${log}"; then
    die_k err_kvm_disk_failed "${name}" "${log}"
  fi
  rm -f "${raw}" "${log}"
}

# _kvm_push_volume NAME VOLUME: the transfer archive a fork/rollback staged in
# the volume directory is copied into the guest home. It is removed afterwards:
# from then on the qcow2 is the only copy of the data.
_kvm_push_volume() {
  local name="$1" volume="$2" archive
  archive="$(_kvm_volume_dir "${volume}")/home.tar.gz"
  [[ -f "${archive}" ]] || return 0
  _kvm_ssh "${name}" root 'tar xzf - -C /home/agent && chown -R agent:agent /home/agent' <"${archive}" \
    || die_k err_kvm_volume_push "${name}"
  rm -f "${archive}"
}

_kvm_push_env() {
  local name="$1" env_file="$2"
  [[ -f "${env_file}" ]] || return 0
  _kvm_ssh "${name}" root 'install -d -m 0700 -o agent -g agent /home/agent/.config/agent-workspace && cat > /home/agent/.config/agent-workspace/env && chown agent:agent /home/agent/.config/agent-workspace/env && chmod 0600 /home/agent/.config/agent-workspace/env' <"${env_file}" \
    || die_k err_kvm_env "${name}"
}

eng_create_persistent() {
  local name="$1" image="$2" volume="$3" env_file="$4" web_port="$5" agent="$6"
  local dir disk key ssh_port
  dir="$(_kvm_dir "${name}")"
  disk="${dir}/disk.qcow2"
  if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
    printf 'dry-run: virsh define %s; virsh start %s\n' "${name}" "${name}"
    return 0
  fi
  : "${agent}"
  install -d -m 0700 "${KVM_ROOT}" "${dir}"

  # An image ref that was committed (snapshot) is a qcow2 next to the OCI
  # cache; any other ref has to be exported from its OCI form first.
  if [[ ! -f "$(_kvm_commit_file "${image}")" ]]; then
    eng_image_exists "${image}" || eng_pull "${image}"
  fi

  if [[ ! -f "${dir}/id_ed25519" ]]; then
    ssh-keygen -q -t ed25519 -N '' -C "agent-workspace-${name}" -f "${dir}/id_ed25519" >/dev/null \
      || die_k err_kvm_seed_failed "${name}"
    chmod 0600 "${dir}/id_ed25519"
  fi
  key="$(cat "${dir}/id_ed25519.pub")"

  [[ -f "${disk}" ]] || _kvm_build_disk "${name}" "${image}" "${disk}"
  [[ -f "${dir}/kernel" ]] || cp -f "$(_kvm_image_dir "${image}")/vmlinuz" "${dir}/kernel"
  [[ -f "${dir}/initramfs.img" ]] || cp -f "$(_kvm_image_dir "${image}")/initramfs.img" "${dir}/initramfs.img"
  : >"${dir}/console.log"

  ssh_port="$(_kvm_free_port 22022)"
  printf '%s\n' "${ssh_port}" >"${dir}/ssh-port"
  printf '%s\n' "${web_port}" >"${dir}/web-port"
  _kvm_seed "${name}" "${dir}" "${key}"

  _kvm_domain_xml "${name}" "${disk}" "${dir}/seed.iso" "${dir}/console.log" \
    "${dir}/kernel" "${dir}/initramfs.img" "${ssh_port}" "${web_port}" >"${dir}/domain.xml"
  _kvm_virsh define "${dir}/domain.xml" >/dev/null 2>&1 || {
    # a leftover definition from a failed earlier create is replaced, not
    # stacked: undefine only this name, then retry once.
    _kvm_virsh undefine --nvram "${name}" >/dev/null 2>&1 || true
    _kvm_virsh define "${dir}/domain.xml" >/dev/null 2>&1 || die_k err_kvm_domain_define "${name}"
  }
  _kvm_virsh start "${name}" >/dev/null 2>&1 || die_k err_kvm_boot_failed "${name}"

  if ! _kvm_wait_ssh "${name}" "${KVM_READY_TIMEOUT}"; then
    msg_k kvm_console_tail "$(_kvm_console_tail "${name}")"
    die_k err_kvm_ssh_timeout "${name}" "$(_kvm_dir "${name}")/console.log"
  fi
  if ! _kvm_wait_provisioned "${name}" "${KVM_PROVISION_TIMEOUT}"; then
    die_k err_kvm_provision_timeout "${name}" "$(_kvm_dir "${name}")/console.log"
  fi
  _kvm_push_env "${name}" "${env_file}"
  _kvm_push_volume "${name}" "${volume}"
}

eng_create_ephemeral() {
  local name="$1"
  : "${name}"
  die_k err_kvm_ephemeral
}

eng_start() {
  local name="$1" state=""
  state="$(_kvm_domain_state "${name}")"
  [[ "${state}" == "running" ]] && return 0
  _kvm_virsh start "${name}" >/dev/null 2>&1 || die_k err_kvm_boot_failed "${name}"
  if ! _kvm_wait_ssh "${name}" "${KVM_READY_TIMEOUT}"; then
    msg_k kvm_console_tail "$(_kvm_console_tail "${name}")"
    die_k err_kvm_ssh_timeout "${name}" "$(_kvm_dir "${name}")/console.log"
  fi
}

eng_stop() {
  local name="$1" waited=0 state=""
  state="$(_kvm_domain_state "${name}")"
  [[ -z "${state}" || "${state}" == "shut off" ]] && return 0
  _kvm_virsh shutdown "${name}" >/dev/null 2>&1 || true
  while :; do
    state="$(_kvm_domain_state "${name}")"
    [[ "${state}" == "shut off" ]] && return 0
    if [[ "${waited}" -ge "${KVM_STOP_TIMEOUT}" ]]; then
      warn_k kvm_force_off "${name}"
      _kvm_virsh destroy "${name}" >/dev/null 2>&1 || true
      _kvm_wait_domain_running "${name}" 5 >/dev/null 2>&1 || true
      state="$(_kvm_domain_state "${name}")"
      [[ "${state}" == "shut off" ]] && return 0
      die_k err_kvm_stop_timeout "${name}"
    fi
    sleep 1
    waited=$((waited + 1))
  done
}

eng_remove() {
  local name="$1" dir
  dir="$(_kvm_dir "${name}")"
  if eng_container_exists "${name}"; then
    _kvm_virsh destroy "${name}" >/dev/null 2>&1 || true
    _kvm_virsh undefine --nvram "${name}" >/dev/null 2>&1 \
      || _kvm_virsh undefine "${name}" >/dev/null 2>&1 || true
  fi
  [[ -n "${dir}" ]] && rm -rf "${dir}"
}

# --- volumes: transfer buffers, never a live bind --------------------------

eng_volume_exists() {
  local volume="$1" name
  [[ -d "$(_kvm_volume_dir "${volume}")" ]] && return 0
  name="$(_kvm_instance_of_volume "${volume}")"
  [[ -n "${name}" && -f "$(_kvm_dir "${name}")/disk.qcow2" ]]
}

eng_volume_create() {
  local volume="$1"
  install -d -m 0700 "$(_kvm_volume_dir "${volume}")"
}

eng_volume_remove() {
  local volume="$1"
  # The live home is in the qcow2 and is removed with the instance. This only
  # drops the transfer buffer, so it can never be the wrong half of a delete.
  rm -rf "$(_kvm_volume_dir "${volume}")"
}

eng_volume_archive() {
  local volume="$1" dir="$2" image="$3" name tar
  : "${image}"
  name="$(_kvm_instance_of_volume "${volume}")"
  if [[ -n "${name}" ]] && [[ "$(_kvm_domain_state "${name}")" == "running" ]]; then
    mkdir -p "${dir}"
    tar="${dir}/home.tar.gz"
    _kvm_ssh "${name}" root 'tar czf - -C /home/agent .' >"${tar}" \
      || return 1
    [[ -s "${tar}" ]] && tar -tzf "${tar}" >/dev/null 2>&1
    return 0
  fi
  # A staged archive (restore/fork buffer) archives by copying, without booting.
  if [[ -f "$(_kvm_volume_dir "${volume}")/home.tar.gz" ]]; then
    mkdir -p "${dir}"
    cp -f "$(_kvm_volume_dir "${volume}")/home.tar.gz" "${dir}/home.tar.gz"
    return 0
  fi
  # Stopped instance with a real disk: boot it, archive, stop it again. There is
  # no offline ext4 reader in the dependency set, and booting is the same probe
  # every other verb uses, so the archive is taken from the live filesystem
  # rather than from a half-parsed disk image.
  if [[ -n "${name}" ]]; then
    eng_start "${name}" || return 1
    mkdir -p "${dir}"
    tar="${dir}/home.tar.gz"
    _kvm_ssh "${name}" root 'tar czf - -C /home/agent .' >"${tar}" || {
      eng_stop "${name}" >/dev/null 2>&1 || true
      return 1
    }
    eng_stop "${name}" >/dev/null 2>&1 || true
    [[ -s "${tar}" ]] && tar -tzf "${tar}" >/dev/null 2>&1
    return 0
  fi
  return 1
}

eng_volume_restore_archive() {
  local volume="$1" archive="$2" image="$3" name
  : "${image}"
  [[ -f "${archive}" ]] || return 1
  tar -tzf "${archive}" >/dev/null 2>&1 || return 1
  name="$(_kvm_instance_of_volume "${volume}")"
  if [[ -z "${name}" ]]; then
    # Rollback removed the domain first: stage the archive, create pushes it.
    install -d -m 0700 "$(_kvm_volume_dir "${volume}")"
    cp -f "${archive}" "$(_kvm_volume_dir "${volume}")/home.tar.gz"
    return 0
  fi
  if [[ "$(_kvm_domain_state "${name}")" != "running" ]]; then
    eng_start "${name}" || return 1
    if ! _kvm_ssh "${name}" root 'tar xzf - -C /home/agent && chown -R agent:agent /home/agent' <"${archive}"; then
      eng_stop "${name}" >/dev/null 2>&1 || true
      return 1
    fi
    eng_stop "${name}" >/dev/null 2>&1 || true
    return 0
  fi
  _kvm_ssh "${name}" root 'tar xzf - -C /home/agent && chown -R agent:agent /home/agent' <"${archive}"
}

eng_volume_clone() {
  local src="$1" dst="$2" image="$3" stage
  : "${image}"
  stage="$(mktemp -d)"
  if ! eng_volume_archive "${src}" "${stage}" "${image}"; then
    rm -rf "${stage}"
    return 1
  fi
  install -d -m 0700 "$(_kvm_volume_dir "${dst}")"
  cp -f "${stage}/home.tar.gz" "$(_kvm_volume_dir "${dst}")/home.tar.gz"
  rm -rf "${stage}"
}

eng_volume_export_path() {
  local volume="$1" rel="$2" outdir="$3" image="$4" name
  : "${image}"
  name="$(_kvm_instance_of_volume "${volume}")"
  if [[ -n "${name}" ]] && [[ "$(_kvm_domain_state "${name}")" == "running" ]]; then
    _kvm_ssh "${name}" root "tar czf - -C /home/agent $(printf '%q' "${rel}")" >"${outdir}/rescue.tar.gz"
    return 0
  fi
  if [[ -f "$(_kvm_volume_dir "${volume}")/home.tar.gz" ]]; then
    tar xzf "$(_kvm_volume_dir "${volume}")/home.tar.gz" -C "${outdir}" "${rel}" 2>/dev/null \
      && tar czf "${outdir}/rescue.tar.gz" -C "${outdir}" "${rel}"
    return 0
  fi
  return 1
}

# --- exec ------------------------------------------------------------------

# Every command run as the agent sources the instance env file first: the
# container backends inject it with --env-file, and a VM has no such flag. The
# file is mode 0600 and owned by agent, written over the root channel at create.
_kvm_agent_command() {
  local cmd
  cmd="$(_kvm_remote_cmd "$@")"
  printf '%s' "set -a; [ -f \"\$HOME/.config/agent-workspace/env\" ] && . \"\$HOME/.config/agent-workspace/env\"; set +a; exec bash -lc $(printf '%q' "${cmd}")"
}

eng_exec() {
  local name="$1" cmd
  shift
  if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
    printf 'dry-run: ssh %s %s\n' "${name}" "$*"
    return 0
  fi
  cmd="$(_kvm_agent_command "$@")"
  _kvm_ssh "${name}" agent -t "${cmd}"
}

# The administrative channel is root over the same key: the container backends'
# eng_exec_test runs as root inside the container, and the root toggle needs the
# same privilege to write /etc/sudoers.d. The key stays 0600 on the host.
eng_exec_root() {
  local name="$1"
  shift
  : "${name}"
  if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
    printf 'dry-run: virsh console %s\n' "${name}"
    return 0
  fi
  if [[ ! -t 0 ]]; then
    _kvm_ssh "${name}" agent -t "$(_kvm_agent_command "sudo -n" "$@")"
    return 0
  fi
  msg_k kvm_console_attached "${name}"
  _kvm_virsh console --force "${name}"
}

eng_exec_test() {
  local name="$1"
  shift
  _kvm_ssh "${name}" root "$(_kvm_remote_cmd "$@")" >/dev/null 2>&1
}

eng_exec_capture() {
  local name="$1"
  shift
  _kvm_ssh "${name}" root "$(_kvm_remote_cmd "$@")" 2>/dev/null || true
}

eng_exec_background() {
  local name="$1" user="$2" cmd
  shift 2
  cmd="$(_kvm_remote_cmd "$@")"
  _kvm_ssh "${name}" "${user}" "nohup bash -lc $(printf '%q' "${cmd}") >/dev/null 2>&1 < /dev/null &" >/dev/null 2>&1
}

eng_exec_nofail() {
  local name="$1"
  shift
  _kvm_ssh "${name}" root "$(_kvm_remote_cmd "$@")" >/dev/null 2>&1 || true
}

eng_logs() {
  local name="$1" tail="${2:-50}" follow="${3:-0}" file
  file="$(_kvm_dir "${name}")/console.log"
  if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
    printf 'dry-run: tail -n %s %s\n' "${tail}" "${file}"
    return 0
  fi
  [[ -f "${file}" ]] || return 1
  if [[ "${follow}" -eq 1 ]]; then
    tail -n "${tail}" -f "${file}"
  else
    tail -n "${tail}" "${file}"
  fi
}

# --- snapshots: a disk-level commit ---------------------------------------

eng_commit() {
  local name="$1" ref="$2" dir target was_running=0
  dir="$(_kvm_dir "${name}")"
  target="$(_kvm_commit_file "${ref}")"
  [[ -f "${dir}/disk.qcow2" ]] || die_k err_kvm_no_disk "${name}"
  [[ "${DRY_RUN:-0}" -eq 1 ]] && {
    printf 'dry-run: qemu-img convert -O qcow2 %s %s\n' "${dir}/disk.qcow2" "${target}"
    return 0
  }
  if [[ "$(_kvm_domain_state "${name}")" == "running" ]]; then
    was_running=1
    eng_stop "${name}"
  fi
  install -d -m 0700 "${KVM_ROOT}/images"
  qemu-img convert -O qcow2 "${dir}/disk.qcow2" "${target}.tmp" >/dev/null 2>&1 \
    || { rm -f "${target}.tmp"; die_k err_kvm_commit_failed "${ref}"; }
  mv "${target}.tmp" "${target}"
  printf '%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"${target}.created"
  if [[ "${was_running}" -eq 1 ]]; then
    eng_start "${name}"
  fi
}
