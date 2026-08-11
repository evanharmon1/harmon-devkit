FROM ghcr.io/evanharmon1/harmon-devcontainer:sha-72bafab6a169214c546ba5f5e1061b6ee7ea9e2c@sha256:3f939c366f4448a9b455b7d8e8548c4e057658206b0e9949eb2412dc57930586

USER root

# Add genuinely repository-specific native packages here. Shared tools belong
# in the canonical harmon-init image, not in generated repository Dockerfiles.

COPY .devcontainer/config/ /usr/local/share/devcontainer-config/
RUN /usr/local/sbin/install-harmon-repo-config

USER vscode
