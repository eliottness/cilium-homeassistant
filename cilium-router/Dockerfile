# Global args must be before the first FROM to be usable in FROM lines
ARG CILIUM_VERSION=1.19.0
ARG BUILD_FROM=ghcr.io/home-assistant/amd64-base-debian:bookworm

# Stage 1: Cilium binaries from official image
FROM quay.io/cilium/cilium:v${CILIUM_VERSION} AS cilium

# Stage 2: Addon
FROM ${BUILD_FROM}

# Install runtime deps + download kubectl
ARG TARGETARCH
RUN apt-get update && apt-get install -y --no-install-recommends \
    bash curl jq iproute2 iptables ipset kmod \
    libelf1 mount wireguard-tools ca-certificates \
    && KUBE_ARCH=$(echo "${TARGETARCH}" | sed 's/aarch64/arm64/') \
    && curl -fsSL "https://dl.k8s.io/release/v1.32.3/bin/linux/${KUBE_ARCH}/kubectl" -o /usr/bin/kubectl \
    && chmod +x /usr/bin/kubectl \
    && rm -rf /var/lib/apt/lists/*

# Cilium agent + tools
COPY --from=cilium /usr/bin/cilium-agent /usr/bin/
COPY --from=cilium /usr/bin/cilium /usr/bin/
COPY --from=cilium /usr/bin/cilium-dbg /usr/bin/
COPY --from=cilium /usr/bin/cilium-mount /usr/bin/
COPY --from=cilium /usr/bin/cilium-sysctlfix /usr/bin/
# BPF programs (required by agent)
COPY --from=cilium /var/lib/cilium/bpf /var/lib/cilium/bpf
# init-container.sh for clean-cilium-state
COPY --from=cilium /init-container.sh /usr/local/bin/cilium-init-container.sh

# Addon overlay
COPY rootfs /

RUN chmod +x /etc/cont-init.d/*.sh \
    && chmod +x /etc/services.d/*/run \
    && chmod +x /etc/services.d/*/finish 2>/dev/null || true \
    && chmod +x /usr/local/bin/*.sh

RUN mkdir -p /var/run/cilium /var/lib/cilium /etc/cilium \
    /tmp/cilium/config-map /run/cilium/cgroupv2

ARG BUILD_ARCH BUILD_DATE BUILD_DESCRIPTION BUILD_NAME BUILD_REF BUILD_REPOSITORY BUILD_VERSION
LABEL \
    io.hass.name="${BUILD_NAME}" \
    io.hass.description="${BUILD_DESCRIPTION}" \
    io.hass.arch="${BUILD_ARCH}" \
    io.hass.type="addon" \
    io.hass.version=${BUILD_VERSION}
