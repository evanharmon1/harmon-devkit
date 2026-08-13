FROM ghcr.io/evanharmon1/harmon-devcontainer:sha-e46904b128015bc03bc1b804826ac042e748c70e@sha256:0e968d0328ed1686d08acf0d28c55612d61fb9d3b5f6f9f8e54835fa232416a6

USER root

# Add genuinely repository-specific native packages here. Shared tools belong
# in the canonical harmon-init image, not in generated repository Dockerfiles.

COPY .devcontainer/config/ /usr/local/share/devcontainer-config/
RUN /usr/local/sbin/install-harmon-repo-config

USER vscode
