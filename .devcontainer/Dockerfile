FROM ghcr.io/evanharmon1/harmon-devcontainer:sha-1be1d57da824932e0e41ff258ebafa0ade80d310@sha256:0e53bfba52d741cc48b931eed6bebaa3c5f4d115b847112b8c6ac371b094b292

USER root

# Add genuinely repository-specific native packages here. Shared tools belong
# in the canonical harmon-init image, not in generated repository Dockerfiles.

COPY .devcontainer/config/ /usr/local/share/devcontainer-config/
RUN /usr/local/sbin/install-harmon-repo-config

# Prepend ~/.local/bin onto PATH for every process the container ever runs —
# baked into the image, not devcontainer.json's containerEnv: that layer's
# ${containerEnv:PATH} cannot self-expand while Docker is creating the
# container (it is passed to `docker run -e` literally, unresolved, which
# breaks the container's own shell). A Dockerfile ENV directive is Docker's
# own, working self-reference and applies identically to any docker exec,
# not only an interactive login shell — the antigravity bot-autonomy
# wrapper's precedence over the system agy binary depends on this.
ENV PATH="/home/vscode/.local/bin:${PATH}"

USER vscode
