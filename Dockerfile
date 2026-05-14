# Agent VPN — local-only image. Build: `docker build -t agentvpn .`
#
# ⚠️ DO NOT PUSH THE BUILT IMAGE TO ANY REGISTRY (public or private).
# Once you populate /etc/nvpn-client/config with the real UDID
# (whether by editing config.template before build, or via -e UDID=... at
# runtime), that secret becomes part of the image filesystem. `docker push`
# would exfiltrate it. Build locally, use locally. (As of nvpn-client 0.9.x
# the UDID alone is sufficient for auth — no separate ELYSIUM_AUTH_CLIENT_KEY
# is needed.)
#
# Architecture:
#   - Base: alpine:3.21 (~70 MB final image, vs ~170 MB for debian:12-slim)
#   - Bundles nvpn-client_0.9.x.deb from data/debs/ — extracted manually
#     with `ar x` + `unzstd` (Alpine has no dpkg, but the deb's payload
#     is just a zstd-compressed tar). The deb's postinst (systemctl,
#     default-config writer) is intentionally NOT run; we ship our own
#     entrypoint and config.template.
#   - Adds wireguard-go (built from source) so wg-quick works without a
#     host kernel module.
#   - Adds microsocks (built from source) for the optional in-container
#     SOCKS5 proxy used by the Browser-through-VPN recipe.
#
# This works on Alpine because nvpn-client (amd64) is statically-linked
# Go — no glibc / musl mismatch concerns. The arm64 build is dynamically
# linked and would need gcompat; we don't consume it here.
#
# Bump WG_GO_REF when upgrading wireguard-go; tags:
#   https://git.zx2c4.com/wireguard-go/refs/tags
# Bump MICROSOCKS_REF when upgrading microsocks; tags:
#   https://github.com/rofl0r/microsocks/tags
# Bump NVPN_DEB_VERSION when upgrading the Norton client deb (and replace
# the file in data/debs/).

ARG WG_GO_REF=0.0.20250522
ARG MICROSOCKS_REF=v1.0.5
ARG NVPN_DEB_VERSION=0.9.0-beta1

# --- wireguard-go (Go static build) ----------------------------------------
FROM golang:1.23-alpine AS wireguard-go-builder
ARG WG_GO_REF
RUN apk add --no-cache git make \
    && git clone --depth 1 --branch ${WG_GO_REF} https://git.zx2c4.com/wireguard-go /src/wireguard-go \
    && make -C /src/wireguard-go \
    && install -m755 /src/wireguard-go/wireguard-go /wireguard-go

# --- microsocks ------------------------------------------------------------
FROM alpine:3.21 AS microsocks-builder
ARG MICROSOCKS_REF
RUN apk add --no-cache build-base git \
    && git clone --depth 1 --branch ${MICROSOCKS_REF} https://github.com/rofl0r/microsocks /src/microsocks \
    && make -C /src/microsocks \
    && install -m755 /src/microsocks/microsocks /microsocks

# --- pi-ml-scan (Rust + tract-onnx ML scanner) ------------------------------
FROM rust:1.87-alpine AS pi-ml-scan-builder
RUN apk add --no-cache musl-dev
COPY tools/pi-ml-scan/ /src/pi-ml-scan/
WORKDIR /src/pi-ml-scan
RUN cargo build --release \
    && install -m755 target/release/pi-ml-scan /pi-ml-scan

# --- nvpn-client unpack ----------------------------------------------------
# Extract the deb's payload into a clean rootfs that we can COPY in one shot.
FROM alpine:3.21 AS nvpn-unpack
ARG NVPN_DEB_VERSION
RUN apk add --no-cache binutils zstd tar
COPY data/debs/nvpn-client_${NVPN_DEB_VERSION}_amd64.deb /tmp/nvpn-client.deb
RUN mkdir -p /tmp/deb /out \
    && cd /tmp/deb \
    && ar x /tmp/nvpn-client.deb \
    && unzstd data.tar.zst -o data.tar \
    && tar -xf data.tar -C /out \
    && rm -rf /tmp/deb /tmp/nvpn-client.deb \
    && ls -l /out/usr/bin

# --- final image -----------------------------------------------------------
FROM alpine:3.21

# Runtime deps. Notes:
#   - bash:        entrypoint is bash (uses arrays, indirect expansion)
#   - grep:        GNU grep (entrypoint uses grep -oP for DNS extraction)
#   - bind-tools:  Alpine equivalent of Debian's dnsutils (dig, nslookup)
#   - wireguard-tools: provides wg, wg-quick (wg-quick auto-detects wireguard-go)
RUN apk add --no-cache \
        bash \
        bind-tools \
        ca-certificates \
        curl \
        grep \
        iproute2 \
        iptables \
        procps-ng \
        wireguard-tools \
    && rm -rf /var/cache/apk/*

COPY --from=wireguard-go-builder /wireguard-go /usr/bin/wireguard-go
COPY --from=microsocks-builder /microsocks /usr/bin/microsocks
COPY --from=pi-ml-scan-builder /pi-ml-scan /usr/local/bin/pi-ml-scan

# Drop in the deb payload (binaries + systemd unit, skipping the postinst).
COPY --from=nvpn-unpack /out/usr/bin/nvpn-client            /usr/bin/nvpn-client
COPY --from=nvpn-unpack /out/usr/bin/nvpn-client-daemon     /usr/bin/nvpn-client-daemon
COPY --from=nvpn-unpack /out/usr/bin/nvpn-mcp-server        /usr/bin/nvpn-mcp-server
RUN chmod +x /usr/bin/nvpn-client /usr/bin/nvpn-client-daemon /usr/bin/nvpn-mcp-server \
    && mkdir -p /etc/nvpn-client /var/log/nvpn-client /etc/wireguard

# wg-quick calls sysctl; wrap so permission errors in unprivileged containers are ignored
RUN mv /sbin/sysctl /sbin/sysctl.real \
    && printf '%s\n' '#!/bin/sh' '/sbin/sysctl.real "$@" 2>/dev/null || true' > /sbin/sysctl \
    && chmod +x /sbin/sysctl

COPY config.template /etc/nvpn-client/config.template
RUN install -m600 /etc/nvpn-client/config.template /etc/nvpn-client/config

# Prompt injection heuristic scanner (used by safefetch entrypoint command)
COPY data/pi-patterns.txt /usr/local/share/pi-patterns.txt
COPY scripts/pi-scan.sh /usr/local/bin/pi-scan.sh
RUN chmod +x /usr/local/bin/pi-scan.sh

COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["daemon"]
