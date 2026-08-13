FROM ghcr.io/evanharmon1/harmon-devcontainer:sha-597f9ee24732a9bb8d2b34bedd8541d0bc8ffe1f@sha256:25b373e75eb626578708458e18c7887e6f4e92de49b00ee41c9af17862d0e7e9

USER root

# Add genuinely repository-specific native packages here. Shared tools belong
# in the canonical harmon-init image, not in generated repository Dockerfiles.

COPY .devcontainer/config/ /usr/local/share/devcontainer-config/
RUN /usr/local/sbin/install-harmon-repo-config

USER vscode
