# Use the official Cilium image as base — includes clang, llvm, bpftool,
# all BPF programs, libraries, and the agent binary.
ARG CILIUM_VERSION=1.19.1
FROM quay.io/cilium/cilium:v${CILIUM_VERSION}

# Add tools needed by our addon scripts
ARG TARGETARCH
RUN apt-get update && apt-get install -y --no-install-recommends curl \
    && KUBE_ARCH="${TARGETARCH}" \
    && curl -fsSL "https://dl.k8s.io/release/v1.32.3/bin/linux/${KUBE_ARCH}/kubectl" -o /usr/bin/kubectl \
    && chmod +x /usr/bin/kubectl \
    && rm -rf /var/lib/apt/lists/*

# Copy init-container.sh to a known location
RUN cp /init-container.sh /usr/local/bin/cilium-init-container.sh 2>/dev/null || true

# Addon overlay
COPY rootfs /

RUN chmod +x /run.sh \
    && chmod +x /usr/local/bin/*.sh 2>/dev/null || true

RUN mkdir -p /var/run/cilium /var/lib/cilium /etc/cilium \
    /tmp/cilium/config-map /run/cilium/cgroupv2 /data

ARG BUILD_ARCH BUILD_DATE BUILD_DESCRIPTION BUILD_NAME BUILD_REF BUILD_REPOSITORY BUILD_VERSION
LABEL \
    io.hass.name="${BUILD_NAME}" \
    io.hass.description="${BUILD_DESCRIPTION}" \
    io.hass.arch="${BUILD_ARCH}" \
    io.hass.type="addon" \
    io.hass.version=${BUILD_VERSION}

CMD ["/run.sh"]
