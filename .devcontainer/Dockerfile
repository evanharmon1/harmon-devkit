# hadolint global ignore=DL3008,DL3059
FROM mcr.microsoft.com/devcontainers/base:ubuntu-24.04

ARG TARGETARCH

# ---------- version pins ----------
# Each ARG_VERSION line is annotated with a `# renovate:` comment so Renovate
# can auto-PR new releases. See renovate.json for the regex manager config.
# NODE_MAJOR is intentionally unmanaged — Node major bumps are deliberate.
ARG NODE_MAJOR=24
# renovate: datasource=github-releases depName=mvdan/sh extractVersion=^v?(?<version>.+)$
ARG SHFMT_VERSION=3.13.1
# renovate: datasource=github-releases depName=hadolint/hadolint extractVersion=^v?(?<version>.+)$
ARG HADOLINT_VERSION=2.14.0
# renovate: datasource=github-releases depName=rhysd/actionlint extractVersion=^v?(?<version>.+)$
ARG ACTIONLINT_VERSION=1.7.12
# renovate: datasource=github-releases depName=terraform-docs/terraform-docs extractVersion=^v?(?<version>.+)$
ARG TERRAFORM_DOCS_VERSION=0.24.0
# renovate: datasource=github-releases depName=mikefarah/yq extractVersion=^v?(?<version>.+)$
ARG YQ_VERSION=4.53.2
# renovate: datasource=github-releases depName=zellij-org/zellij extractVersion=^v?(?<version>.+)$
ARG ZELLIJ_VERSION=0.44.3
# renovate: datasource=github-releases depName=raine/workmux extractVersion=^v?(?<version>.+)$
ARG WORKMUX_VERSION=0.1.212
# renovate: datasource=github-releases depName=njbrake/agent-of-empires extractVersion=^v?(?<version>.+)$
ARG AOE_VERSION=1.10.1
# renovate: datasource=npm depName=@anthropic-ai/claude-code
ARG CLAUDE_CODE_VERSION=2.1.167
# renovate: datasource=npm depName=@openai/codex
ARG CODEX_VERSION=0.137.0
# renovate: datasource=npm depName=@google/gemini-cli
ARG GEMINI_CLI_VERSION=0.45.2
# renovate: datasource=github-releases depName=asheshgoplani/agent-deck extractVersion=^v?(?<version>.+)$
ARG AGENT_DECK_VERSION=1.9.47
# renovate: datasource=github-releases depName=joshmedeski/sesh extractVersion=^v?(?<version>.+)$
ARG SESH_VERSION=2.26.2
# renovate: datasource=npm depName=dmux
ARG DMUX_VERSION=5.9.0
# renovate: datasource=npm depName=snyk
ARG SNYK_VERSION=1.1305.1
# renovate: datasource=npm depName=@playwright/test
ARG PLAYWRIGHT_VERSION=1.60.0
# renovate: datasource=npm depName=@playwright/cli
ARG PLAYWRIGHT_CLI_VERSION=0.1.13
# renovate: datasource=github-releases depName=getsops/sops extractVersion=^v?(?<version>.+)$
ARG SOPS_VERSION=3.13.1
# renovate: datasource=github-releases depName=nektos/act extractVersion=^v?(?<version>.+)$
ARG ACT_VERSION=0.2.89
# renovate: datasource=github-releases depName=wagoodman/dive extractVersion=^v?(?<version>.+)$
ARG DIVE_VERSION=0.13.1
# renovate: datasource=github-releases depName=antonmedv/fx extractVersion=^v?(?<version>.+)$
ARG FX_VERSION=39.2.0
# renovate: datasource=github-releases depName=charmbracelet/glow extractVersion=^v?(?<version>.+)$
ARG GLOW_VERSION=2.1.2
# renovate: datasource=github-releases depName=jesseduffield/lazygit extractVersion=^v?(?<version>.+)$
ARG LAZYGIT_VERSION=0.62.2
# renovate: datasource=github-releases depName=XAMPPRocky/tokei extractVersion=^v?(?<version>.+)$
ARG TOKEI_VERSION=13.0.0-alpha.0
# renovate: datasource=github-releases depName=dlvhdr/gh-dash extractVersion=^v?(?<version>.+)$
ARG GH_DASH_VERSION=4.24.1
# renovate: datasource=github-releases depName=charmbracelet/gum extractVersion=^v?(?<version>.+)$
ARG GUM_VERSION=0.17.0
# renovate: datasource=github-releases depName=o2sh/onefetch extractVersion=^v?(?<version>.+)$
ARG ONEFETCH_VERSION=2.27.1
# renovate: datasource=github-releases depName=wtfutil/wtf extractVersion=^v?(?<version>.+)$
ARG WTF_VERSION=0.49.1
# renovate: datasource=github-releases depName=ducaale/xh extractVersion=^v?(?<version>.+)$
ARG XH_VERSION=0.25.3
# renovate: datasource=github-releases depName=evilmartians/lefthook extractVersion=^v?(?<version>.+)$
ARG LEFTHOOK_VERSION=2.1.9
# renovate: datasource=github-releases depName=gitleaks/gitleaks extractVersion=^v?(?<version>.+)$
ARG GITLEAKS_VERSION=8.30.1
# renovate: datasource=github-releases depName=lycheeverse/lychee extractVersion=^lychee-v(?<version>.+)$
ARG LYCHEE_VERSION=0.24.2
# renovate: datasource=github-releases depName=alexpasmantier/television extractVersion=^v?(?<version>.+)$
ARG TV_VERSION=0.15.7
# renovate: datasource=github-releases depName=astral-sh/uv extractVersion=^v?(?<version>.+)$
ARG UV_VERSION=0.11.25
# renovate: datasource=github-releases depName=starship/starship extractVersion=^v?(?<version>.+)$
ARG STARSHIP_VERSION=1.25.1
ARG UV_INSTALL_DIR=/usr/local/bin

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# ---------- apt packages ----------
# Only install packages not already in the base image.
# base:ubuntu-24.04 already provides: ca-certificates, curl, git, gnupg, jq,
# lsof, nano, wget, xz-utils, and others. We only add the extras we need.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bat \
        btop \
        direnv \
        dnsutils \
        eza \
        fd-find \
        ffmpeg \
        fzf \
        git-crypt \
        git-delta \
        git-extras \
        git-lfs \
        gron \
        htop \
        imagemagick \
        jo \
        lynx \
        mc \
        micro \
        mkcert \
        nmap \
        ncdu \
        ncurses-bin \
        netcat-openbsd \
        pandoc \
        pv \
        ripgrep \
        sd \
        shellcheck \
        socat \
        strace \
        tealdeer \
        tmux \
        tree \
        unzip \
        vim \
        w3m \
        zip \
        zoxide \
        zsh \
    && git lfs install --system \
    && rm -rf /var/lib/apt/lists/* \
    && ln -sf /usr/bin/batcat /usr/local/bin/bat \
    && ln -sf /usr/bin/fdfind /usr/local/bin/fd \
    && chsh -s /usr/bin/zsh vscode

# ---------- fzf shell integration ----------
# The base devcontainer image excludes /usr/share/doc via dpkg config, so
# the fzf apt package's key-bindings.zsh is stripped out. The oh-my-zsh fzf
# plugin expects it at this path. Reinstall fzf docs from the .deb before
# the apt cache is cleared, or generate via 'fzf --zsh' if available.
RUN if [ ! -f /usr/share/doc/fzf/examples/key-bindings.zsh ]; then \
        mkdir -p /usr/share/doc/fzf/examples \
        && apt-get update -qq \
        && apt-get download fzf \
        && dpkg-deb -x fzf_*.deb / \
        && rm -f fzf_*.deb \
        && rm -rf /var/lib/apt/lists/*; \
    fi

# ---------- oh-my-zsh ----------
# Install as the vscode user so config lands in /home/vscode/.oh-my-zsh.
# Custom plugins (autosuggestions, syntax-highlighting) are cloned into the
# custom plugins directory. The .zshrc is written here with the full plugin
# list so it's baked into the image.
USER vscode
RUN if [ ! -d "$HOME/.oh-my-zsh" ]; then \
        sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended; \
    fi \
    && git clone --depth=1 https://github.com/zsh-users/zsh-autosuggestions \
        "${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins/zsh-autosuggestions" \
    && git clone --depth=1 https://github.com/zsh-users/zsh-syntax-highlighting \
        "${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins/zsh-syntax-highlighting"

# ---------- oh-my-tmux ----------
# Install as vscode user: clone the repo and symlink .tmux.conf, copy .tmux.conf.local
# for user customisation. This replaces any prior custom tmux.conf.
RUN git clone --single-branch https://github.com/gpakosz/.tmux.git "$HOME/.tmux" \
    && ln -s -f "$HOME/.tmux/.tmux.conf" "$HOME/.tmux.conf"
USER root

# ---------- Node.js ----------
# Installed via NodeSource rather than the devcontainer "node" feature because
# features run AFTER the Dockerfile build — we need npm available here for the
# global package install layer below.
RUN install -d -m 0755 /etc/apt/keyrings \
    && curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
        | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg \
    && echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODE_MAJOR}.x nodistro main" \
        >/etc/apt/sources.list.d/nodesource.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends nodejs \
    && corepack enable pnpm \
    && rm -rf /var/lib/apt/lists/*

# Suppress Corepack's interactive download prompt so pnpm installs silently.
ENV COREPACK_ENABLE_DOWNLOAD_PROMPT=0

# ---------- code-quality linters ----------
RUN case "${TARGETARCH}" in \
        "amd64") export SHFMT_ARCH="amd64" HADOLINT_ARCH="x86_64" ACTIONLINT_ARCH="amd64" ;; \
        "arm64") export SHFMT_ARCH="arm64" HADOLINT_ARCH="arm64" ACTIONLINT_ARCH="arm64" ;; \
        *) echo "Unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; \
    esac \
    && curl -fsSL "https://github.com/mvdan/sh/releases/download/v${SHFMT_VERSION}/shfmt_v${SHFMT_VERSION}_linux_${SHFMT_ARCH}" \
        -o /usr/local/bin/shfmt \
    && chmod +x /usr/local/bin/shfmt \
    && curl -fsSL "https://github.com/hadolint/hadolint/releases/download/v${HADOLINT_VERSION}/hadolint-Linux-${HADOLINT_ARCH}" \
        -o /usr/local/bin/hadolint \
    && chmod +x /usr/local/bin/hadolint \
    && curl -fsSL "https://github.com/rhysd/actionlint/releases/download/v${ACTIONLINT_VERSION}/actionlint_${ACTIONLINT_VERSION}_linux_${ACTIONLINT_ARCH}.tar.gz" \
        | tar -xz -C /usr/local/bin actionlint

# ---------- lefthook + gitleaks ----------
RUN case "${TARGETARCH}" in \
        "amd64") export LEFTHOOK_ARCH="x86_64" GITLEAKS_ARCH="x64" ;; \
        "arm64") export LEFTHOOK_ARCH="arm64" GITLEAKS_ARCH="arm64" ;; \
        *) echo "Unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; \
    esac \
    && curl -fsSL "https://github.com/evilmartians/lefthook/releases/download/v${LEFTHOOK_VERSION}/lefthook_${LEFTHOOK_VERSION}_Linux_${LEFTHOOK_ARCH}" \
        -o /usr/local/bin/lefthook \
    && chmod +x /usr/local/bin/lefthook \
    && curl -fsSL "https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/gitleaks_${GITLEAKS_VERSION}_linux_${GITLEAKS_ARCH}.tar.gz" \
        | tar -xz -C /usr/local/bin gitleaks

# ---------- infrastructure tools ----------
RUN case "${TARGETARCH}" in \
        "amd64") export TFDOCS_ARCH="amd64" YQ_ARCH="amd64" ;; \
        "arm64") export TFDOCS_ARCH="arm64" YQ_ARCH="arm64" ;; \
        *) echo "Unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; \
    esac \
    && curl -fsSL "https://github.com/terraform-docs/terraform-docs/releases/download/v${TERRAFORM_DOCS_VERSION}/terraform-docs-v${TERRAFORM_DOCS_VERSION}-linux-${TFDOCS_ARCH}.tar.gz" \
        | tar -xz -C /usr/local/bin terraform-docs \
    && curl -fsSL "https://github.com/mikefarah/yq/releases/download/v${YQ_VERSION}/yq_linux_${YQ_ARCH}" \
        -o /usr/local/bin/yq \
    && chmod +x /usr/local/bin/yq

# ---------- secrets management ----------
RUN case "${TARGETARCH}" in \
        "amd64") export SOPS_ARCH="amd64" ;; \
        "arm64") export SOPS_ARCH="arm64" ;; \
        *) echo "Unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; \
    esac \
    && curl -fsSL "https://github.com/getsops/sops/releases/download/v${SOPS_VERSION}/sops-v${SOPS_VERSION}.linux.${SOPS_ARCH}" \
        -o /usr/local/bin/sops \
    && chmod +x /usr/local/bin/sops

# ---------- local GitHub Actions runner ----------
RUN case "${TARGETARCH}" in \
        "amd64") export ACT_ARCH="x86_64" ;; \
        "arm64") export ACT_ARCH="arm64" ;; \
        *) echo "Unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; \
    esac \
    && curl -fsSL "https://github.com/nektos/act/releases/download/v${ACT_VERSION}/act_Linux_${ACT_ARCH}.tar.gz" \
        | tar -xz -C /usr/local/bin act

# ---------- CLI utilities (binary downloads) ----------
RUN case "${TARGETARCH}" in \
        "amd64") export GLOW_ARCH="x86_64" GUM_ARCH="x86_64" XH_ARCH="x86_64" FX_ARCH="amd64" \
            LAZYGIT_ARCH="x86_64" TOKEI_ARCH="x86_64" DIVE_ARCH="amd64" \
            GH_DASH_ARCH="amd64" WTF_ARCH="amd64" \
            LYCHEE_ARCH="x86_64" TV_ARCH="x86_64" ;; \
        "arm64") export GLOW_ARCH="arm64" GUM_ARCH="arm64" XH_ARCH="aarch64" FX_ARCH="arm64" \
            LAZYGIT_ARCH="arm64" TOKEI_ARCH="aarch64" DIVE_ARCH="arm64" \
            GH_DASH_ARCH="arm64" WTF_ARCH="arm64" \
            LYCHEE_ARCH="aarch64" TV_ARCH="aarch64" ;; \
        *) echo "Unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; \
    esac \
    && curl -fsSL "https://github.com/wagoodman/dive/releases/download/v${DIVE_VERSION}/dive_${DIVE_VERSION}_linux_${DIVE_ARCH}.tar.gz" \
        | tar -xz -C /usr/local/bin dive \
    && curl -fsSL "https://github.com/antonmedv/fx/releases/download/${FX_VERSION}/fx_linux_${FX_ARCH}" \
        -o /usr/local/bin/fx \
    && chmod +x /usr/local/bin/fx \
    && curl -fsSL "https://github.com/charmbracelet/glow/releases/download/v${GLOW_VERSION}/glow_${GLOW_VERSION}_Linux_${GLOW_ARCH}.tar.gz" \
        | tar -xz --strip-components=1 -C /usr/local/bin "glow_${GLOW_VERSION}_Linux_${GLOW_ARCH}/glow" \
    && curl -fsSL "https://github.com/jesseduffield/lazygit/releases/download/v${LAZYGIT_VERSION}/lazygit_${LAZYGIT_VERSION}_linux_${LAZYGIT_ARCH}.tar.gz" \
        | tar -xz -C /usr/local/bin lazygit \
    && curl -fsSL "https://github.com/XAMPPRocky/tokei/releases/download/v${TOKEI_VERSION}/tokei-${TOKEI_ARCH}-unknown-linux-gnu.tar.gz" \
        | tar -xz -C /usr/local/bin tokei \
    && curl -fsSL "https://github.com/ducaale/xh/releases/download/v${XH_VERSION}/xh-v${XH_VERSION}-${XH_ARCH}-unknown-linux-musl.tar.gz" \
        | tar -xz --strip-components=1 -C /usr/local/bin "xh-v${XH_VERSION}-${XH_ARCH}-unknown-linux-musl/xh" \
    && ln -sf /usr/local/bin/xh /usr/local/bin/xhs \
    && curl -fsSL "https://github.com/charmbracelet/gum/releases/download/v${GUM_VERSION}/gum_${GUM_VERSION}_Linux_${GUM_ARCH}.tar.gz" \
        | tar -xz --strip-components=1 -C /usr/local/bin "gum_${GUM_VERSION}_Linux_${GUM_ARCH}/gum" \
    && curl -fsSL "https://github.com/dlvhdr/gh-dash/releases/download/v${GH_DASH_VERSION}/gh-dash_v${GH_DASH_VERSION}_linux-${GH_DASH_ARCH}" \
        -o /usr/local/bin/gh-dash \
    && chmod +x /usr/local/bin/gh-dash \
    && curl -fsSL "https://github.com/wtfutil/wtf/releases/download/v${WTF_VERSION}/wtf_${WTF_VERSION}_linux_${WTF_ARCH}.tar.gz" \
        | tar -xz -C /usr/local/bin wtfutil \
    && if [ "${TARGETARCH}" = "amd64" ]; then \
        curl -fsSL "https://github.com/o2sh/onefetch/releases/download/${ONEFETCH_VERSION}/onefetch-linux.tar.gz" \
            | tar -xz -C /usr/local/bin; \
    fi \
    && curl -fsSL "https://github.com/lycheeverse/lychee/releases/download/lychee-v${LYCHEE_VERSION}/lychee-${LYCHEE_ARCH}-unknown-linux-gnu.tar.gz" \
        | tar -xz --strip-components=1 -C /usr/local/bin "lychee-${LYCHEE_ARCH}-unknown-linux-gnu/lychee" \
    && curl -fsSL "https://github.com/alexpasmantier/television/releases/download/${TV_VERSION}/tv-${TV_VERSION}-${TV_ARCH}-unknown-linux-gnu.tar.gz" \
        | tar -xz --strip-components=1 -C /usr/local/bin "tv-${TV_VERSION}-${TV_ARCH}-unknown-linux-gnu/tv"

# ---------- terminal / workflow tools ----------
RUN case "${TARGETARCH}" in \
        "amd64") export ZELLIJ_ARCH="x86_64" WORKMUX_ARCH="amd64" AOE_ARCH="amd64" AGENT_DECK_ARCH="amd64" SESH_ARCH="x86_64" ;; \
        "arm64") export ZELLIJ_ARCH="aarch64" WORKMUX_ARCH="arm64" AOE_ARCH="arm64" AGENT_DECK_ARCH="arm64" SESH_ARCH="arm64" ;; \
        *) echo "Unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; \
    esac \
    && curl -fsSL "https://github.com/zellij-org/zellij/releases/download/v${ZELLIJ_VERSION}/zellij-${ZELLIJ_ARCH}-unknown-linux-musl.tar.gz" \
        | tar -xz -C /usr/local/bin zellij \
    && curl -fsSL "https://github.com/raine/workmux/releases/download/v${WORKMUX_VERSION}/workmux-linux-${WORKMUX_ARCH}.tar.gz" \
        | tar -xz -C /usr/local/bin workmux \
    && curl -fsSL "https://github.com/njbrake/agent-of-empires/releases/download/v${AOE_VERSION}/aoe-linux-${AOE_ARCH}.tar.gz" \
        | tar -xz -C /tmp "aoe-linux-${AOE_ARCH}" \
    && install -m 0755 "/tmp/aoe-linux-${AOE_ARCH}" /usr/local/bin/aoe \
    && rm -f "/tmp/aoe-linux-${AOE_ARCH}" \
    && curl -fsSL "https://github.com/asheshgoplani/agent-deck/releases/download/v${AGENT_DECK_VERSION}/agent-deck_${AGENT_DECK_VERSION}_linux_${AGENT_DECK_ARCH}.tar.gz" \
        | tar -xz -C /usr/local/bin agent-deck \
    && curl -fsSL "https://github.com/joshmedeski/sesh/releases/download/v${SESH_VERSION}/sesh_Linux_${SESH_ARCH}.tar.gz" \
        | tar -xz -C /usr/local/bin sesh

# ---------- uv (Python package manager) ----------
RUN curl -LsSf https://astral.sh/uv/${UV_VERSION}/install.sh | env UV_INSTALL_DIR="${UV_INSTALL_DIR}" sh

# ---------- starship prompt ----------
RUN curl -fsSL https://starship.rs/install.sh | sh -s -- --yes --version v${STARSHIP_VERSION}

# ---------- devcontainer config files ----------
# Bake to /usr/local/share/ rather than /tmp/ — Coder/devcontainer hosts mount
# /tmp as a tmpfs at runtime, which would shadow the build-time files and break
# the post-create runtime seeders that need to read from this location.
COPY .devcontainer/config/ /usr/local/share/devcontainer-config/
RUN tic -x /usr/local/share/devcontainer-config/ghostty.terminfo

# ---------- Node.js global packages (stable) ----------
# Packages with unpinned or rarely-changing versions go in this early layer
# so they stay cached when the volatile versions below are bumped by Renovate.
# hadolint ignore=DL3016
RUN npm install -g \
        "@commitlint/cli" \
        "@commitlint/config-conventional" \
        "markdownlint-cli2" \
    && npm cache clean --force

# ---------- Playwright (browser automation CLI) ----------
# Two packages: @playwright/test for the test runner + standard CLI (screenshot,
# pdf, codegen), and @playwright/cli for the AI-agent-oriented CLI that provides
# the SKILL.md skill installation (`playwright-cli install --skills`).
# Both packages install browsers separately because @playwright/cli bundles an
# alpha playwright-core that may expect a different chromium revision than
# @playwright/test. The dual-install ensures each finds the revision it expects.
# PLAYWRIGHT_BROWSERS_PATH ensures the Chromium binary stored at build time
# is discoverable by the non-root vscode user at runtime.
#
# Placed before the volatile npm-globals layer so that frequent Renovate bumps
# to claude-code / gemini-cli / codex don't force a Chromium re-download.
ENV PLAYWRIGHT_BROWSERS_PATH=/ms-playwright
RUN npm install -g \
        "@playwright/test@${PLAYWRIGHT_VERSION}" \
        "@playwright/cli@${PLAYWRIGHT_CLI_VERSION}" \
    && npx playwright install --with-deps chromium \
    && (playwright-cli install --with-deps chromium 2>/dev/null || true) \
    && chmod -R o+rx ${PLAYWRIGHT_BROWSERS_PATH} \
    && rm -rf /var/lib/apt/lists/* \
    && npm cache clean --force

# ---------- Python packages for agent-deck Telegram bridge ----------
RUN uv pip install --system --break-system-packages --no-cache toml aiogram

# ---------- dotfile config ----------
# /usr/local/share/devcontainer-config/ is kept (not cleaned up) so that
# post-create scripts can seed persistent volumes that shadow the baked-in
# files (~/.agent-deck and ~/.claude are both volume-mounted at runtime).
RUN install -d -m 0755 /home/vscode/.config/zellij \
    && install -d -m 0755 /home/vscode/.config/micro \
    && install -d -m 0755 /home/vscode/.config/git \
    && install -d -m 0755 /home/vscode/.config/television/cable \
    && install -d -m 0755 /home/vscode/.config \
    && install -d -m 0755 /home/vscode/.agent-deck \
    && install -d -m 0755 /home/vscode/.shell-history \
    && install -m 0644 /usr/local/share/devcontainer-config/tmux.conf.local /home/vscode/.tmux.conf.local \
    && install -m 0644 /usr/local/share/devcontainer-config/zellij.kdl /home/vscode/.config/zellij/config.kdl \
    && install -m 0644 /usr/local/share/devcontainer-config/micro-bindings.json /home/vscode/.config/micro/bindings.json `# Rebind quit from Ctrl-Q to Ctrl-X — Ctrl-Q conflicts with agent-deck's detach keybind` \
    && install -m 0644 /usr/local/share/devcontainer-config/agent-deck.toml /home/vscode/.agent-deck/config.toml \
    && install -m 0644 /usr/local/share/devcontainer-config/starship.toml /home/vscode/.config/starship.toml \
    && install -m 0644 /usr/local/share/devcontainer-config/gitconfig /home/vscode/.config/git/config `# XDG git config — merged with ~/.gitconfig at runtime; provides image-baked aliases` \
    && install -m 0644 /usr/local/share/devcontainer-config/television/cable/gh-issues.toml /home/vscode/.config/television/cable/gh-issues.toml \
    && install -m 0644 /usr/local/share/devcontainer-config/zshrc /home/vscode/.zshrc \
    && chown -R vscode:vscode /home/vscode/.config /home/vscode/.tmux.conf.local /home/vscode/.agent-deck /home/vscode/.shell-history /home/vscode/.zshrc

# ---------- Claude Code managed settings + hooks ----------
# Install claude-settings.json as Claude Code's Linux "managed settings" file.
# Highest precedence in the settings hierarchy, always loaded by the CLI, and
# baked into the image — survives any container rebuild or volume deletion.
# Source of truth: .devcontainer/config/claude-settings.json (checked into git).
#
# Hook scripts referenced from managed-settings.json are installed alongside
# at /etc/claude-code/hooks/ so they share the same image-baked, volume-proof
# location. Source of truth: .devcontainer/config/claude-hooks/ (checked into git).
RUN install -d -m 0755 /etc/claude-code /etc/claude-code/hooks \
    && install -m 0644 /usr/local/share/devcontainer-config/claude-settings.json /etc/claude-code/managed-settings.json \
    && install -m 0755 /usr/local/share/devcontainer-config/claude-hooks/post-edit-format.sh             /etc/claude-code/hooks/post-edit-format.sh \
    && install -m 0755 /usr/local/share/devcontainer-config/claude-hooks/protect-files.sh               /etc/claude-code/hooks/protect-files.sh \
    && install -m 0755 /usr/local/share/devcontainer-config/claude-hooks/block-no-verify.sh             /etc/claude-code/hooks/block-no-verify.sh \
    && install -m 0755 /usr/local/share/devcontainer-config/claude-hooks/enforce-conventional-commits.sh /etc/claude-code/hooks/enforce-conventional-commits.sh \
    && install -m 0755 /usr/local/share/devcontainer-config/claude-hooks/session-start-context.sh       /etc/claude-code/hooks/session-start-context.sh

# ---------- Node.js global packages (volatile) ----------
# Packages with Renovate-managed version pins that change frequently. This layer
# is intentionally LAST so that version bumps (especially claude-code, which
# updates multiple times per week) only invalidate this single cheap layer
# instead of triggering expensive rebuilds of Playwright/Chromium and everything
# else above.
# hadolint ignore=DL3016
RUN npm install -g \
        "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" \
        "@google/gemini-cli@${GEMINI_CLI_VERSION}" \
        "@openai/codex@${CODEX_VERSION}" \
        "dmux@${DMUX_VERSION}" \
        "snyk@${SNYK_VERSION}" \
    && npm cache clean --force

USER vscode
