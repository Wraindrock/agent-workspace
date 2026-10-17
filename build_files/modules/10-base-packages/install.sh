#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../../lib/common.sh
source "${COMMON_LIB:?COMMON_LIB must point at build_files/lib/common.sh}"

# Everything here is required for the image to be usable as an agent host.
install_rpms \
  bash-completion \
  bind-utils \
  ca-certificates \
  cloud-init \
  curl \
  dnf5-plugins \
  findutils \
  git \
  git-lfs \
  gnupg2 \
  hostname \
  iproute \
  iputils \
  jq \
  less \
  openssh-clients \
  openssh-server \
  procps-ng \
  qemu-guest-agent \
  psmisc \
  rsync \
  sudo \
  tar \
  unzip \
  which \
  wget \
  xz \
  zip \
  zstd

# yq is packaged for most Fedora releases; a missing package must not break the
# image because the runtime CLI degrades gracefully without it.
install_optional_rpms yq

git lfs install --system --skip-repo || warn "git lfs system hooks were not installed"
