# fm-lab — public container image (clean, host-path-free).
#
# This is the PUBLIC, derived variant of the maintainer's dev container
# (.devcontainer/Dockerfile). It contains ONLY the fm-lab base layer:
# everything needed to run the analysis tool — DuckDB CLI, the stock webbed XML
# extension, Node/npm, and the Leiden clustering engine — with NO agent CLIs, NO
# firewall/sandbox tooling, NO maintainer dotfiles, and NO host-specific mounts.
#
# The repository is NOT copied into the image. It arrives at runtime as a bind /
# workspace mount (see docker-compose.yml / the published devcontainer.json), so
# `git pull` keeps the code current without a rebuild.
#
# Multi-stage skeleton (only `base` is shipped today):
#   base    → (this file)                                   — pure fm-lab tool
#   claude  → +@anthropic-ai/claude-code + firewall opt-in  — not yet here
#   agent-* → +codex / gemini-cli …                         — future work
#   harness → +hermes / pi / nanoclaw …                     — future work
#   fm-lab-{ingestion,api,web} → slim per-component images  — future work
# Each future stage is `FROM base AS …` and only ADDS its CLI + config; the base
# never changes (the agent-agnostic core).

# ---- Stage: base ----------------------------------------------------------------
# Debian release pinned explicitly (-bookworm): the bare node:<version> tag follows the
# official images' default Debian, which moved on to trixie — that would silently swap
# the OS (apt packages, glibc) on the next version bump.
# The Node version is derived: ingestion/version_check.json → tested_baseline.
# node_recommended_version, written by tools/build-container-env.mjs (tools/init.sh
# recommends the same version). Edit it there, never here.
FROM node:26.13.0-bookworm AS base

ARG TZ=Etc/UTC
ENV TZ="$TZ"

# Basic tooling needed by the fm-lab harness + a comfortable shell.
# Deliberately WITHOUT the dev-only / agent-only packages from the dev image:
#   bubblewrap, socat        → Claude Code sandbox (claude stage)
#   iptables, ipset,         → egress firewall (claude stage)
#   iproute2, dnsutils,
#   aggregate
#   gh                       → maintainer convenience
# Kept: the conversion harness's runtime deps (unzip for solution-bundle imports and
# the MBS docset, jq, awk via the base image's mawk, rsync, git) + editors/search niceties.
RUN apt-get update && apt-get install -y --no-install-recommends \
  ca-certificates \
  curl \
  wget \
  unzip \
  gnupg2 \
  git \
  jq \
  rsync \
  make \
  build-essential \
  python3 \
  python3-pip \
  locales \
  less \
  procps \
  sudo \
  zsh \
  nano \
  vim \
  ripgrep \
  fd-find \
  tree \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

# Debian ships fd-find's binary as `fdfind` to avoid a name clash. Expose it as `fd`
# (ripgrep already provides `rg`).
RUN ln -s "$(command -v fdfind)" /usr/local/bin/fd

# python-igraph — the Leiden community-detection engine
# (tools/graph-export/cluster_leiden.py). Without it, the `auto` engine detection in
# cluster.sh / the fm-graph-cluster sweep (`python3 -c "import igraph"`) silently
# falls back to the Louvain baseline. Baked at build time (one `pip install` lifts
# every container onto the better Leiden method). Installed into the
# SYSTEM python3 on purpose: the cluster scripts invoke a bare `python3`, not a venv,
# so a venv install would not be seen. --break-system-packages: Debian 12 marks the
# system environment externally-managed (PEP 668). The igraph wheel bundles the C
# core (manylinux aarch64 + x86_64, cp311) → no compilation. Pinned for reproducibility.
ARG PYIGRAPH_VERSION=0.11.8
RUN python3 -m pip install --no-cache-dir --break-system-packages \
  "python-igraph==${PYIGRAPH_VERSION}"

# Locale parity with the validated conversion pipeline. The dev image runs de_DE as
# the default locale; the convert harness was validated under it. We generate both
# de_DE and en_US and keep de_DE.UTF-8 as the default so conversion output stays
# byte-identical to the tested baseline (locale can affect awk/sort collation).
# Override at runtime via the LANG/LC_ALL env if you prefer English CLI messages.
RUN sed -i -e 's/# de_DE.UTF-8 UTF-8/de_DE.UTF-8 UTF-8/' \
           -e 's/# en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen && \
  locale-gen && \
  update-locale LANG=de_DE.UTF-8
ENV LANG=de_DE.UTF-8
ENV LANGUAGE=de_DE:de
ENV LC_ALL=de_DE.UTF-8

# Orientation marker (same as the dev image).
ENV DEVCONTAINER=true

# Ensure the node user owns the npm global prefix + its config dir.
RUN mkdir -p /usr/local/share/npm-global && \
  chown -R node:node /usr/local/share

# Workspace mount point — matches the published devcontainer.json's
# containerWorkspaceFolder and docker-compose.yml's working_dir.
RUN mkdir -p /workspaces/fm-lab && chown -R node:node /workspaces/fm-lab
WORKDIR /workspaces/fm-lab

# git-delta — nicer git diffs in the container (small, quality-of-life).
ARG GIT_DELTA_VERSION=0.18.2
RUN ARCH=$(dpkg --print-architecture) && \
  wget "https://github.com/dandavison/delta/releases/download/${GIT_DELTA_VERSION}/git-delta_${GIT_DELTA_VERSION}_${ARCH}.deb" && \
  dpkg -i "git-delta_${GIT_DELTA_VERSION}_${ARCH}.deb" && \
  rm "git-delta_${GIT_DELTA_VERSION}_${ARCH}.deb"

# DuckDB CLI — pinned to the tested baseline (ingestion/version_check.json
# → tested_baseline.duckdb_min_version; tools/build-container-env.mjs keeps this ARG
# in sync). Single static binary per arch in a tar.gz (duckdb-cli-linux-<arch>.tar.gz,
# the asset name since DuckDB 2.0); the arch suffix matches dpkg --print-architecture
# directly, so no name mapping is needed.
ARG DUCKDB_VERSION=2.0.0
RUN ARCH=$(dpkg --print-architecture) && \
  wget "https://github.com/duckdb/duckdb/releases/download/v${DUCKDB_VERSION}/duckdb-cli-linux-${ARCH}.tar.gz" && \
  tar -xzf "duckdb-cli-linux-${ARCH}.tar.gz" -C /usr/local/bin duckdb && \
  rm "duckdb-cli-linux-${ARCH}.tar.gz" && \
  chmod +x /usr/local/bin/duckdb

# DuckDB community extension: webbed (XML/HTML reader — provides xml_extract_text,
# used by the LayoutObjects analysis + several SQL templates). Community extensions
# are version-locked to the DuckDB binary, so the extension version MUST equal
# DUCKDB_VERSION. The community repository pins no webbed version: INSTALL
# always fetches the CURRENT webbed build published for this DuckDB version. We bake the signed stock extension into the image and `LOAD webbed` picks
# it up offline. Installed into the node user's ~/.duckdb (the
# default extension home), so it persists across rebuilds.
#
# WEBBED_REFRESH: cache-bust token. Because INSTALL pins no webbed version, bumping
# this date invalidates the layer and forces a re-pull of the current build.
# NOTE: this is the SIGNED STOCK webbed only — the maintainer's unsigned SAX-patched
# build (a dev streaming optimization) is intentionally NOT shipped here. Without it
# the conversion safely falls back to the stock DOM path (bit-identical, no streaming).
ARG WEBBED_REFRESH=2026-10-29
# Installed through the CLI, not fetched with wget: since DuckDB 2.0 a community
# extension only loads with the .info metadata file INSTALL writes next to it (it
# names the community repository, whose signing key LOAD then accepts) — a bare
# downloaded file fails the signature check. HOME points the default extension
# directory at the node user.
RUN echo "webbed refresh token: ${WEBBED_REFRESH}" && \
  HOME=/home/node DUCKDB_AGENT_MODE=0 duckdb :memory: -c "FORCE INSTALL webbed FROM community; LOAD webbed;" && \
  chown -R node:node /home/node/.duckdb

# Copy the node_modules-volume init script (chowns the root-owned empty named
# volumes to `node` so the first `npm install` can write into them — see
# init-node-modules.sh / docker-compose.yml). It gets a narrowly-scoped NOPASSWD
# sudoers entry: the ONLY privileged op the node user may run. (No firewall script
# here — that belongs to the claude stage.)
COPY init-node-modules.sh /usr/local/bin/
USER root
RUN chmod +x /usr/local/bin/init-node-modules.sh && \
  echo "node ALL=(root) NOPASSWD: /usr/local/bin/init-node-modules.sh" > /etc/sudoers.d/node-nodemodules && \
  chmod 0440 /etc/sudoers.d/node-nodemodules

# The repo arrives as a host bind mount owned by the HOST uid. When that uid differs
# from the container's node user (uid 1000), git refuses to operate in the workspace
# ("dubious ownership", CVE-2022-24765) — which also leaves VS Code's Git view dead.
# The mount target is fixed by docker-compose.yml, so whitelist exactly that path
# system-wide (/etc/gitconfig: user-independent, baked into the image, effective in
# every container/exec session). Ownership itself is deliberately left untouched.
RUN git config --system --add safe.directory /workspaces/fm-lab

# Default shell + editor (set before dropping to node — ENV is user-independent).
ENV SHELL=/bin/zsh
ENV EDITOR=nano
ENV VISUAL=nano

# npm global packages on PATH (kept ready for the agent stages; base installs none).
ENV NPM_CONFIG_PREFIX=/usr/local/share/npm-global
ENV PATH=$PATH:/usr/local/share/npm-global/bin

# fm-lab runs as the unprivileged node user (uid 1000) — matches the host bind-mount
# uid mapping on Linux and the Docker Desktop remap on macOS/Windows.
USER node


# ---- Stage: claude (fm-lab + Claude Code) ---------------------------------------
# Additive layer on top of `base`: the agent-agnostic tool core is unchanged; this
# only ADDS the Claude Code CLI, the opt-in egress firewall, and a bundled copy of the
# duckdb-skills plugin. Build it with `--target claude` (the docker-compose.claude.yml
# overlay does this). Auth is runtime-only — no secret is ever baked in.
FROM base AS claude

USER root

# Firewall + sandbox tooling that the base image deliberately omits:
#   iptables, ipset, iproute2, dnsutils, aggregate → the egress firewall
#   bubblewrap, socat                              → Claude Code sandbox-runtime deps
RUN apt-get update && apt-get install -y --no-install-recommends \
  iptables \
  ipset \
  iproute2 \
  dnsutils \
  aggregate \
  bubblewrap \
  socat \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

# Egress firewall script + a narrowly-scoped NOPASSWD sudoers entry (alongside the
# init-node-modules entry inherited from base). The script is opt-in: it no-ops
# gracefully when NET_ADMIN is absent, so it never blocks container start.
# firewall-refresh-loop.sh runs unprivileged (no sudoers entry): it only triggers
# refresh-doc-domains.sh periodically.
COPY init-firewall.sh refresh-doc-domains.sh firewall-refresh-loop.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/init-firewall.sh /usr/local/bin/refresh-doc-domains.sh /usr/local/bin/firewall-refresh-loop.sh && \
  echo "node ALL=(root) NOPASSWD: /usr/local/bin/init-firewall.sh" > /etc/sudoers.d/node-firewall && \
  echo "node ALL=(root) NOPASSWD: /usr/local/bin/refresh-doc-domains.sh" > /etc/sudoers.d/node-refresh-doc-domains && \
  chmod 0440 /etc/sudoers.d/node-firewall /etc/sudoers.d/node-refresh-doc-domains

# Auth preflight — logs the Claude Code credential state (env / saved login) + the exact
# next command at container start, so the agent decision + auth are a guided step rather
# than something the user discovers at the first interactive `claude`. Runs unprivileged;
# never fails the boot (always exits 0).
COPY claude-auth-preflight.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/claude-auth-preflight.sh

# Project-settings seed (permissions + the duckdb-skills marketplace + enabledPlugins).
# Fallback only: the public repo already ships a committed .claude/settings.json (kept in
# sync from tools/publish-assets/.claude-settings.json by the publisher). The devcontainer
# bootstrap copies this baked seed only if that file is somehow absent — so keep the two
# in sync.
COPY claude-settings.seed.json /opt/fmlab/claude-settings.seed.json

# Bundled duckdb-skills — the recommended DuckDB-doc/query plugin, baked as a
# deterministic OFFLINE copy. The github marketplace stays the ACTIVE wiring (the
# firewall allowlists github.com), so first-run resolution works online out of the
# box; this bundled copy is the offline artifact and lets a fully air-gapped setup do
#   claude plugin marketplace add /opt/duckdb-skills
# RECOMMENDED: pin DUCKDB_SKILLS_REF to a specific commit/tag for reproducibility
# (empty = default-branch HEAD, which drifts).
ARG DUCKDB_SKILLS_REF=
RUN git clone https://github.com/duckdb/duckdb-skills /opt/duckdb-skills && \
  if [ -n "${DUCKDB_SKILLS_REF}" ]; then git -C /opt/duckdb-skills checkout --quiet "${DUCKDB_SKILLS_REF}"; fi && \
  rm -rf /opt/duckdb-skills/.git

# Seed the USER-level Claude config (sandbox OFF — the process sandbox relies on
# bubblewrap, which needs unprivileged user namespaces the Docker Desktop linuxkit
# kernel does not grant; the egress firewall is the enforced boundary instead). This
# file seeds the fmlab-claude named volume on first creation; the volume then persists
# the login token + sessions across rebuilds.
RUN mkdir -p /home/node/.claude && \
  printf '{\n  "sandbox": {\n    "enabled": false\n  }\n}\n' > /home/node/.claude/settings.json && \
  chown -R node:node /home/node/.claude /opt/fmlab /opt/duckdb-skills

# Claude reads user settings from here; also the mount point of the fmlab-claude volume.
ENV CLAUDE_CONFIG_DIR=/home/node/.claude

USER node

# Claude Code CLI + sandbox-runtime (installed as node into the node-owned npm prefix).
ARG CLAUDE_CODE_VERSION=latest
RUN npm install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION} @anthropic-ai/sandbox-runtime
