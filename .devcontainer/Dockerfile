FROM ghcr.io/evanharmon1/harmon-devcontainer:sha-2704ac669ee918f07dda97cf7c3214c6f7c53482@sha256:001126238de369c2e2b9f0b72c41db790b3cf419137d6c2700a92eb53ac05e48

USER root

# Add genuinely repository-specific native packages here. Shared tools belong
# in the canonical harmon-init image, not in generated repository Dockerfiles.

COPY .devcontainer/config/ /usr/local/share/devcontainer-config/
RUN /usr/local/sbin/install-harmon-repo-config

USER vscode
