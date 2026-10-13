#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../../lib/common.sh
source "${COMMON_LIB:?COMMON_LIB must point at build_files/lib/common.sh}"

install_rpms \
  aardvark-dns \
  buildah \
  catatonit \
  crun \
  fuse-overlayfs \
  netavark \
  passt \
  podman \
  podman-docker \
  skopeo \
  uidmap

# Legacy CNI plugins and slirp4netns are gone from newer Fedora bases; keep
# them when they exist so older bases still get a complete stack.
install_optional_rpms containernetworking-plugins slirp4netns

# The image is meant to be usable both as a booted system container and as a
# long-lived container under an outer podman/docker: expose the API socket and
# make sure rootless users can map sub-ids.
enable_unit podman.socket

install -d -m 0755 /etc/containers/registries.conf.d

if ! grep -q '^root:' /etc/subuid 2>/dev/null; then
  echo 'root:100000:65536' >> /etc/subuid
  echo 'root:100000:65536' >> /etc/subgid
fi
