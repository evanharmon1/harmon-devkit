FROM ghcr.io/evanharmon1/harmon-devcontainer:sha-3e264228cc139315e549fc7b19fe95ea8dbbc4d9@sha256:27e89a2b284086a4f1669a93645c21a5d6951db3cfc468b4443b8a9b3b00076f

USER root

# Add genuinely repository-specific native packages here. Shared tools belong
# in the canonical harmon-init image, not in generated repository Dockerfiles.

COPY .devcontainer/config/ /usr/local/share/devcontainer-config/
RUN /usr/local/sbin/install-harmon-repo-config

USER vscode
