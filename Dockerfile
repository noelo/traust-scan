# Containerfile.toolchain — complete runtime image for Traust.
#
# Everything a consumer needs in one image: pinned scanner binaries, Python
# stack (traust-engine + contracts + traust-ledger + traust), and
# harness skill data. SCI k8s jobs and CI runners pull this and go.
#
# Build (always use the wrapper — it reads pins from external-tools.yaml
# and pre-builds Python wheels from sibling repos):
#   ./scripts/build-toolchain-image.sh
#   ./scripts/build-toolchain-image.sh --tag myregistry/harness-toolchain:v0.331
#   ./scripts/build-toolchain-image.sh --no-db
#
# Use in a k8s Job (SCI):
#   image: registry.internal/harness-toolchain:v0.331
#   args: ["doctor", "--profile", "secure-code-audit"]
#
# Use locally:
#   podman run --rm -v $PWD:/workspace:Z harness-toolchain:latest \
#     doctor --profile secure-code-audit

FROM registry.access.redhat.com/ubi9/ubi-minimal:latest AS base

ARG TARGETARCH

# Versions pinned from config/external-tools.yaml — bump here when pins advance.
ARG OPENGREP_VERSION=1.25.0
ARG GITLEAKS_VERSION=8.30.1
ARG SYFT_VERSION=1.48.0
ARG GRYPE_VERSION=0.115.0
ARG OSV_SCANNER_VERSION=2.4.0
ARG COSIGN_VERSION=3.1.1
ARG GOVULNCHECK_VERSION=1.6.0
ARG SKOPEO_VERSION=1.23.0
ARG YARA_VERSION=4.5.8
ARG PIP_AUDIT_VERSION=2.10.1

LABEL name="harness-toolchain" \
      summary="Traust — complete runtime image" \
      description="All-in-one image: pinned scanner binaries (grype, osv-scanner, \
govulncheck, opengrep, gitleaks, syft, cosign, skopeo, yara, pip-audit), the full \
Python stack (traust-engine, contracts, traust-ledger, traust), and \
skill data. Pull, mount a target, run a profile." \
      vendor="Red Hat, Inc."

# System deps for yara build and general tooling
RUN microdnf install -y \
      git tar gzip unzip findutils \
      python3.11 python3.11-pip \
      skopeo \
    && microdnf clean all

# Install Go (needed for govulncheck)
ARG GO_VERSION=1.23.0
RUN curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-${TARGETARCH}.tar.gz" \
    | tar -C /usr/local -xz
ENV PATH="/usr/local/go/bin:/root/go/bin:/root/.opengrep/cli/latest:${PATH}"

# --- Direct binary downloads from upstream GitHub releases ---

# opengrep (install script handles arch detection; -v pins version)
RUN curl -fsSL https://raw.githubusercontent.com/opengrep/opengrep/main/install.sh \
    | bash -s -- -v "v${OPENGREP_VERSION}"

# gitleaks
RUN ARCH=$([ "$TARGETARCH" = "arm64" ] && echo "arm64" || echo "x64") && \
    curl -fsSL "https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/gitleaks_${GITLEAKS_VERSION}_linux_${ARCH}.tar.gz" \
    | tar -C /usr/local/bin -xz gitleaks

# syft
RUN curl -fsSL "https://github.com/anchore/syft/releases/download/v${SYFT_VERSION}/syft_${SYFT_VERSION}_linux_${TARGETARCH}.tar.gz" \
    | tar -C /usr/local/bin -xz syft

# grype
RUN curl -fsSL "https://github.com/anchore/grype/releases/download/v${GRYPE_VERSION}/grype_${GRYPE_VERSION}_linux_${TARGETARCH}.tar.gz" \
    | tar -C /usr/local/bin -xz grype

# osv-scanner
RUN ARCH=$([ "$TARGETARCH" = "arm64" ] && echo "arm64" || echo "amd64") && \
    curl -fsSL "https://github.com/google/osv-scanner/releases/download/v${OSV_SCANNER_VERSION}/osv-scanner_linux_${ARCH}" \
      -o /usr/local/bin/osv-scanner && chmod +x /usr/local/bin/osv-scanner

# cosign
RUN ARCH=$([ "$TARGETARCH" = "arm64" ] && echo "arm64" || echo "amd64") && \
    curl -fsSL "https://github.com/sigstore/cosign/releases/download/v${COSIGN_VERSION}/cosign-linux-${ARCH}" \
      -o /usr/local/bin/cosign && chmod +x /usr/local/bin/cosign

# govulncheck
RUN GOBIN=/usr/local/bin go install "golang.org/x/vuln/cmd/govulncheck@v${GOVULNCHECK_VERSION}"

# --- Hybrid tools ---

# yara (from EPEL or build — using prebuilt RPM)
RUN microdnf install -y yara 2>/dev/null \
    || (curl -fsSL "https://github.com/VirusTotal/yara/releases/download/v${YARA_VERSION}/yara-${YARA_VERSION}.tar.gz" \
        | tar -C /tmp -xz && cd /tmp/yara-${YARA_VERSION} \
        && ./bootstrap.sh && ./configure && make -j$(nproc) && make install \
        && rm -rf /tmp/yara-*) \
    || true

# pip-audit
RUN python3.11 -m pip install --no-cache-dir "pip-audit==${PIP_AUDIT_VERSION}"

# joern is too large for the base image (JVM + ~800MB). Skills that need it
# should extend this image or use the impact profile separately.

# --- Python stack: harness engine + contracts + traust-ledger + harness CLI ---
# The build script pre-builds pure-Python wheels from sibling repos into _build/wheels/.
# Native deps (from requirements.txt) are installed from PyPI inside the container.
COPY requirements.txt /tmp/requirements.txt
RUN python3.11 -m pip install --no-cache-dir -r /tmp/requirements.txt && rm /tmp/requirements.txt
COPY _build/wheels/ /tmp/wheels/
# Deps resolved from PyPI at build time: the sibling wheels are pre-built with
# --no-deps, and requirements.txt does NOT cover the harness's real dependency
# chain (traust → traust-engine → traust-contracts → pydantic …) — baking
# wheels with --no-deps --no-index left `pydantic` uninstalled and the
# toolchain CLI crashed at import (ModuleNotFoundError). --find-links finds
# the pre-built siblings locally; everything else comes from PyPI.
RUN python3.11 -m pip install --no-cache-dir --find-links /tmp/wheels \
      /tmp/wheels/*.whl \
    && rm -rf /tmp/wheels

# --- Harness skill data ---
COPY harnessing/ /harness/harnessing/
COPY config/     /harness/config/
# Deployment config (corpus-config, product map, …) is mounted, never baked in.
ENV TRAUST_CONFIG_HOME=/harness/deploy-config
COPY docs/       /harness/docs/
COPY VERSION     /harness/

ENV HARNESS_ROOT=/harness

# --- Populate vuln DBs (can be skipped at build time with --build-arg SKIP_DB=1) ---
ARG SKIP_DB=0
# The osv-scanner cache must be writable by ANY runtime UID: under OpenShift
# SCC the image's USER 1001 is overridden by the namespace-assigned UID
# (1000910000), which cannot read /root/.cache — the doctor crashed with
# PermissionError stat'ing the cache dir. /tmp is mode 1777.
ENV OSV_SCANNER_LOCAL_DB_CACHE_DIRECTORY=/tmp/osv-scanner-cache
ENV GRYPE_DB_CACHE_DIR=/tmp/grype-db
RUN if [ "$SKIP_DB" = "0" ]; then \
      grype db update || true; \
      chmod -R a+rwX /tmp/grype-db || true; \
      osv-scanner scan source --offline-vulnerabilities --download-offline-databases -r /tmp || true; \
    fi

# --- Pi harness (agent skills runtime) ---
# Node 22.19+ required by pi; installed to /usr/local so pi lands on PATH.
# The node tarball ships in the build context (_build/node) — nodejs.org is
# 404-blocked by the cluster's egress proxy for build pods.
# NOTE: x64 build — the target cluster is x86_64 only.
ARG NODE_VERSION=22.23.4
COPY _build/node/node-v${NODE_VERSION}-linux-x64.tar.gz /tmp/node.tar.gz
RUN tar -C /usr/local --strip-components=1 -xzf /tmp/node.tar.gz && rm /tmp/node.tar.gz
RUN npm install -g --ignore-scripts @earendil-works/pi-coding-agent

# Pi agent directory (skills + models config). PI_CODING_AGENT_DIR overrides the
# default ~/.pi/agent so the baked data is found regardless of the runtime HOME.
ENV PI_CODING_AGENT_DIR=/opt/pi-agent

# Traust skills: copy every skill dir containing SKILL.md (stage-nested
# harnessing/<stage>/<skill> AND cross-cutting harnessing/<skill>) flat into
# the agent-dir skills location; Pi discovers SKILL.md dirs recursively.
RUN mkdir -p /opt/pi-agent/skills && \
    find /harness/harnessing -mindepth 1 -maxdepth 3 -type d \
      -exec test -f '{}/SKILL.md' ';' -exec cp -r '{}' /opt/pi-agent/skills/ ';' && \
    ls /opt/pi-agent/skills/

# OpenAI-compatible model endpoints configured from environment variables:
# $MODEL_BASE_URL (endpoint) + $LLMAPIKEY (key, interpolated by pi itself per
# the models docs). Values come from the deepsec `llm-access` Secret at
# runtime — nothing baked in. baseUrl is NOT env-interpolated by pi (only
# apiKey/header values are), so pi-setup writes the agent-dir models.json
# from the template at runtime before pi runs.
COPY pi-models.json /opt/pi-agent/models.json.tmpl
COPY pi-setup.sh /usr/local/bin/pi-setup
RUN chmod -R a+rwX /opt/pi-agent && chmod +x /usr/local/bin/pi-setup

# --- Smoke test: verify all tools resolve ---
RUN opengrep --version && \
    gitleaks version && \
    syft --version && \
    grype --version && \
    osv-scanner --version && \
    cosign version && \
    govulncheck -version && \
    skopeo --version && \
    echo "All tools verified on PATH"

# Runtime HOME must be writable: opengrep extracts its binary to
# $HOME/.cache/opengrep on first scan and syft caches under $HOME/.cache —
# the default HOME=/ breaks both for SCC-assigned non-root UIDs.
ENV HOME=/tmp

USER 1001
WORKDIR /workspace

ENTRYPOINT ["python3.11", "-m", "traust.cli.toolchain"]
CMD ["doctor", "--profile", "secure-code-audit"]
