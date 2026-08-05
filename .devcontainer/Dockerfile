FROM ghcr.io/evanharmon1/harmon-devcontainer:sha-4fd95f15f4bd63d2e8b3ece61fe2d192bcaff532@sha256:6ca4ea14f77b572510183829fce711078a0f2b77ad65b0bbbae1dd499afb339c

USER root

# Add genuinely repository-specific native packages here. Shared tools belong
# in the canonical harmon-init image, not in generated repository Dockerfiles.

COPY .devcontainer/config/ /usr/local/share/devcontainer-config/
RUN /usr/local/sbin/install-harmon-repo-config

USER vscode
