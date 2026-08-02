FROM ghcr.io/evanharmon1/harmon-devcontainer:sha-da2da6f3d1dc14a97387fd6e75ed71d3ccf2cee6@sha256:441fa5b05c4cbfd8b48cc453ced525aed29c696da00796913665339d2377e4c1

USER root

# Add genuinely repository-specific native packages here. Shared tools belong
# in the canonical harmon-init image, not in generated repository Dockerfiles.

COPY .devcontainer/config/ /usr/local/share/devcontainer-config/
RUN /usr/local/sbin/install-harmon-repo-config

USER vscode
