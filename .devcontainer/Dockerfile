FROM ghcr.io/evanharmon1/harmon-devcontainer:sha-dedd863e6e06f98821db77f59e129c1da12ab42b@sha256:cfbf189450076f3c2260c0a1a58654a09f267710c2305564562a8a8e307174f8

USER root

# Add genuinely repository-specific native packages here. Shared tools belong
# in the canonical harmon-init image, not in generated repository Dockerfiles.

COPY .devcontainer/config/ /usr/local/share/devcontainer-config/
RUN /usr/local/sbin/install-harmon-repo-config

USER vscode
