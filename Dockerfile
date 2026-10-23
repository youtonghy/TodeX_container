# syntax=docker/dockerfile:1
#
# TodeX agent container: todex-agentd plus openly licensed agent CLIs.
#
#   docker buildx build --platform linux/amd64,linux/arm64 -t todex_container .
#
# Build todex-agentd from a sibling checkout instead of a release (development):
#
#   docker buildx build --build-arg TODEX_AGENTD_SOURCE=source \
#     --build-context todexbackend=../TodeX_backend -t todex_container .

ARG DEBIAN_IMAGE=debian:trixie-slim
ARG TODEX_AGENTD_SOURCE=release

# Downloads are architecture-independent work, so they run on the build
# platform and pick the target's artifacts.
FROM --platform=$BUILDPLATFORM ${DEBIAN_IMAGE} AS fetch
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
# hadolint ignore=DL3008
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl xz-utils \
    && rm -rf /var/lib/apt/lists/*
ARG TARGETARCH
ARG TODEX_AGENTD_VERSION=2.3.6
ARG NODE_VERSION=24.22.1
WORKDIR /fetch
# Each artifact must be listed exactly once in its publisher's checksum file.
RUN case "$TARGETARCH" in \
        amd64) todex_label=linux-x64-gnu; node_label=linux-x64 ;; \
        arm64) todex_label=linux-arm64-gnu; node_label=linux-arm64 ;; \
        *) echo "unsupported architecture: $TARGETARCH" >&2; exit 1 ;; \
    esac \
    && fetch() { curl -fsSL --proto '=https' --tlsv1.2 -o "$2" "$1"; } \
    && verify() { \
        awk -v name="$2" '{ file = $2; sub(/^\*/, "", file) } file == name { print $1 "  " name }' "$1" > "$2.sha256"; \
        [ "$(wc -l < "$2.sha256")" -eq 1 ] || { echo "$2 is not listed exactly once in $1" >&2; exit 1; }; \
        sha256sum -c "$2.sha256"; \
    } \
    && todex_asset="todex-agentd-v${TODEX_AGENTD_VERSION}-${todex_label}.bin" \
    && todex_base="https://github.com/youtonghy/TodeX_backend/releases/download/v${TODEX_AGENTD_VERSION}" \
    && fetch "$todex_base/SHA256SUMS" todex-SHA256SUMS \
    && fetch "$todex_base/$todex_asset" "$todex_asset" \
    && verify todex-SHA256SUMS "$todex_asset" \
    && install -D -m 0755 "$todex_asset" /out/release/todex-agentd \
    && node_asset="node-v${NODE_VERSION}-${node_label}.tar.xz" \
    && node_base="https://nodejs.org/dist/v${NODE_VERSION}" \
    && fetch "$node_base/SHASUMS256.txt" node-SHASUMS256.txt \
    && fetch "$node_base/$node_asset" "$node_asset" \
    && verify node-SHASUMS256.txt "$node_asset" \
    && mkdir -p /out/node \
    && tar -xJf "$node_asset" -C /out/node --strip-components=1 --no-same-owner \
    && rm -rf /out/node/include /out/node/share/doc

FROM fetch AS agentd-release
RUN install -D -m 0755 /out/release/todex-agentd /out/todex-agentd

FROM rust:1-trixie AS agentd-source
WORKDIR /src
# The named build context from --build-context todexbackend=...
# hadolint ignore=DL3022
COPY --from=todexbackend . .
ARG TODEX_BUILD_VERSION=DEV0.0.0
RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/src/target \
    TODEX_BUILD_VERSION="$TODEX_BUILD_VERSION" cargo build --release --locked \
    && install -D -m 0755 target/release/todex-agentd /out/todex-agentd

# Selected by TODEX_AGENTD_SOURCE; BuildKit skips the stage not used.
# hadolint ignore=DL3006
FROM agentd-${TODEX_AGENTD_SOURCE} AS agentd

FROM ${DEBIAN_IMAGE} AS base
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
# Runtime tools the daemon and the agents call: git/gh, ssh, ps, a shell, and
# the usual helpers agents reach for. setpriv (util-linux) drops privileges.
# hadolint ignore=DL3008
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bash ca-certificates curl gh git jq less openssh-client procps python3 \
        ripgrep tini unzip util-linux xz-utils \
    && rm -rf /var/lib/apt/lists/*
COPY --from=fetch /out/node /opt/node
ENV PATH=/opt/node/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# npm picks each CLI's platform package, so this runs on the target platform.
FROM base AS agents
WORKDIR /opt/todex/agents
COPY agents/package.json agents/package-lock.json ./
RUN npm ci --omit=dev --no-audit --no-fund \
    && npm cache clean --force \
    && node -e 'const l=require("./package-lock.json"); for (const n of Object.keys(require("./package.json").dependencies)) console.log(n + "=" + l.packages["node_modules/" + n].version)' > versions.txt \
    && for cli in codex opencode pi; do "node_modules/.bin/$cli" --version > /dev/null; done

FROM base AS runtime
ARG TODEX_BUILD_VERSION=DEV0.0.0
ARG TODEX_AGENTD_VERSION=2.3.6
ARG NODE_VERSION=24.22.1
LABEL org.opencontainers.image.title="TodeX agent container" \
      org.opencontainers.image.description="todex-agentd with agent CLIs, ready to pair with TodeX Desktop" \
      org.opencontainers.image.version="${TODEX_BUILD_VERSION}" \
      io.todex.agentd.version="${TODEX_AGENTD_VERSION}" \
      io.todex.node.version="${NODE_VERSION}"

COPY --from=agentd /out/todex-agentd /usr/local/bin/todex-agentd
COPY --from=agents /opt/todex/agents /opt/todex/agents
COPY rootfs/ /

# The entrypoint aligns this user's UID/GID with the host before dropping to it.
RUN groupadd --gid 1000 todex \
    && useradd --uid 1000 --gid todex --create-home --shell /bin/bash todex \
    && install -d -o todex -g todex -m 0700 /home/todex/.todex-agent \
    && install -d -o todex -g todex /home/todex/.local /home/todex/.local/bin /workspace \
    && chmod 0755 /usr/local/bin/todex-entrypoint

ENV HOME=/home/todex \
    PATH=/home/todex/.local/bin:/opt/todex/agents/node_modules/.bin:/opt/node/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    TODEX_AGENTD_HOST=0.0.0.0 \
    TODEX_AGENTD_PORT=7345 \
    TODEX_AGENTD_DATA_DIR=/home/todex/.todex-agent \
    TODEX_AGENTD_DEPLOYMENT=container \
    TODEX_AGENTD_IMAGE_CLI_DIR=/opt/todex/agents \
    TODEX_AUTO_UPDATE=0 \
    TODEX_EXTRA_AGENTS=claude-code

WORKDIR /home/todex
EXPOSE 7345
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
    CMD ["sh", "-c", "curl -fsS \"http://127.0.0.1:${TODEX_AGENTD_PORT}/health\" > /dev/null || exit 1"]
STOPSIGNAL SIGTERM
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/todex-entrypoint"]
CMD ["todex-agentd", "serve"]
