# syntax=docker/dockerfile:1
#
# agent-workspace - a declarative, rollback-capable Fedora bootc system
# container for running coding agents and general-purpose agents.
#
# The image is assembled from four declarative inputs:
#   build_files/    ordered, individually enable/disable-able install modules
#   config/         which modules run and which agents are installed
#   system_files/   a verbatim overlay copied to / (systemd units, sysctl, ...)
#   runtime/        the in-image `agent-workspace` control CLI
#
# See docs/architecture.md for the full build contract.

# Base image is selectable at build time; see image.env for alternatives.
ARG BASE_IMAGE=ghcr.io/ublue-os/base-main:latest

# --------------------------------------------------------------------------
# Context stage: exposes the repository tree to the build without adding it
# to the final image filesystem.
# --------------------------------------------------------------------------
FROM scratch AS ctx
COPY build_files /ctx/build_files
COPY config /ctx/config
COPY runtime /ctx/runtime
COPY system_files /ctx/system_files

# --------------------------------------------------------------------------
# Image stage
# --------------------------------------------------------------------------
FROM ${BASE_IMAGE}

ARG BASE_IMAGE
ARG IMAGE_NAME=agent-workspace
ARG IMAGE_REGISTRY=ghcr.io/wraindrock
ARG IMAGE_VERSION=dev
ARG IMAGE_MODULES=all
ARG GIT_SHA=unknown
ARG BUILD_DATE=unknown
ARG AGENT_USER=agent

ENV AGENT_WORKSPACE_IMAGE="${IMAGE_REGISTRY}/${IMAGE_NAME}" \
    AGENT_WORKSPACE_VERSION="${IMAGE_VERSION}" \
    AGENT_WORKSPACE_BASE_IMAGE="${BASE_IMAGE}" \
    AGENT_WORKSPACE_GIT_SHA="${GIT_SHA}" \
    AGENT_WORKSPACE_BUILD_DATE="${BUILD_DATE}" \
    AGENT_WORKSPACE_USER="${AGENT_USER}"

LABEL org.opencontainers.image.title="agent-workspace" \
      org.opencontainers.image.description="Declarative, rollback-capable Fedora bootc system container for coding agents" \
      org.opencontainers.image.vendor="Wraindrock" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.source="https://github.com/wraindrock/agent-workspace" \
      org.opencontainers.image.url="https://github.com/wraindrock/agent-workspace" \
      org.opencontainers.image.documentation="https://github.com/wraindrock/agent-workspace/blob/main/README.md" \
      io.artifacthub.package.keywords="agent,bootc,oci,linux,podman" \
      io.artifacthub.package.license="MIT" \
      io.artifacthub.package.deprecated="false"

# Run the declarative module pipeline. Every module is recorded in the image
# manifest, so the deployed image can always describe how it was produced.
RUN --mount=type=bind,from=ctx,source=/ctx,target=/ctx \
    --mount=type=cache,dst=/var/cache \
    --mount=type=cache,dst=/var/log \
    --mount=type=tmpfs,dst=/tmp \
    /ctx/build_files/build.sh

# Fail the build if the result is not a valid bootc image.
RUN bootc container lint

# --------------------------------------------------------------------------
# systemd is PID 1.
#
# `podman run --systemd=always` does not replace a container's command (checked
# against podman 5.8.4): it only prepares the systemd-friendly mounts and the
# stop signal. Without this CMD the container inherits the base image's
# `/usr/bin/bash`, exits within milliseconds, and install.sh reports a container
# that never boots.
# --------------------------------------------------------------------------
CMD ["/sbin/init"]
