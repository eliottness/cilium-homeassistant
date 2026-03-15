#!/usr/bin/with-contenv bashio
set -euo pipefail

bashio::log.info "=== Cilium Router Addon Init ==="

export NODE_NAME=$(bashio::config 'node_name')

# ── 1. Copy kubeconfig from file path ────────────────────────────
KUBECONFIG_PATH=$(bashio::config 'kubeconfig_path')
if [ ! -f "${KUBECONFIG_PATH}" ]; then
    bashio::log.fatal "Kubeconfig not found at ${KUBECONFIG_PATH}"
    bashio::log.fatal "Place your kubeconfig file there via Samba, SSH, or File Editor addon."
    exit 1
fi
cp "${KUBECONFIG_PATH}" /etc/cilium/kubeconfig
chmod 600 /etc/cilium/kubeconfig
export KUBECONFIG=/etc/cilium/kubeconfig

bashio::log.info "Testing cluster connectivity..."
if ! kubectl cluster-info > /dev/null 2>&1; then
    bashio::log.fatal "Cannot connect to cluster. Check kubeconfig."
    exit 1
fi
bashio::log.info "Cluster connection OK"

# ── 2. Mount BPF filesystem ─────────────────────────────────────
if ! mount | grep -q '/sys/fs/bpf type bpf'; then
    bashio::log.info "Mounting BPF filesystem..."
    mount -t bpf bpf /sys/fs/bpf || {
        bashio::log.fatal "Failed to mount bpffs. Kernel BPF support missing?"
        exit 1
    }
fi

# ── 3. Mount cgroup v2 ──────────────────────────────────────────
if ! mount | grep -q '/run/cilium/cgroupv2 type cgroup2'; then
    bashio::log.info "Mounting cgroup v2..."
    mount -t cgroup2 none /run/cilium/cgroupv2 2>/dev/null || \
        bashio::log.warning "cgroup2 mount failed (may already be available)"
fi

# ── 4. Set sysctls (replaces apply-sysctl-overwrites init container) ─
bashio::log.info "Configuring sysctls..."
sysctl -w net.ipv4.ip_forward=1 2>/dev/null || true
sysctl -w net.ipv4.conf.all.forwarding=1 2>/dev/null || true
sysctl -w net.core.bpf_jit_enable=1 2>/dev/null || true
# rp_filter must be disabled for cilium interfaces (from cilium-sysctlfix)
sysctl -w net.ipv4.conf.all.rp_filter=0 2>/dev/null || true
sysctl -w net.ipv4.conf.default.rp_filter=0 2>/dev/null || true

# ── 5. Create Node object (MANDATORY: CiliumNode OwnerReference) ─
bashio::log.info "Creating/updating Node '${NODE_NAME}'..."
/usr/local/bin/create-node.sh

# ── 6. Build config (replaces "config" init container) ──────────
# cilium-dbg build-config fetches the real cilium-config ConfigMap
# and writes it as files to --config-dir, exactly like the DaemonSet.
bashio::log.info "Fetching Cilium config from cluster..."
export K8S_NODE_NAME="${NODE_NAME}"
export CILIUM_K8S_NAMESPACE="kube-system"
export KUBERNETES_SERVICE_HOST="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' | sed 's|https\?://||;s|:.*||')"
export KUBERNETES_SERVICE_PORT="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' | sed 's|.*:||')"

cilium-dbg build-config \
    --k8s-kubeconfig-path=/etc/cilium/kubeconfig \
    --config-dir=/tmp/cilium/config-map \
    2>&1 || {
    bashio::log.warning "cilium-dbg build-config failed, falling back to manual ConfigMap dump..."
    # Fallback: manually dump ConfigMap as files
    kubectl get configmap cilium-config -n kube-system -o json \
        | jq -r '.data | to_entries[] | "\(.key)\n\(.value)"' \
        | while IFS= read -r key && IFS= read -r value; do
            printf '%s' "${value}" > "/tmp/cilium/config-map/${key}"
        done
}

# Apply overrides for running without kubelet
printf '%s' "false" > /tmp/cilium/config-map/enable-l7-proxy
printf '%s' ""      > /tmp/cilium/config-map/write-cni-conf-when-ready
printf '%s' "false" > /tmp/cilium/config-map/enable-health-check-nodeport
printf '%s' "false" > /tmp/cilium/config-map/cni-exclusive
# Point kubeconfig in the config
printf '%s' "/etc/cilium/kubeconfig" > /tmp/cilium/config-map/k8s-kubeconfig-path

bashio::log.info "Config ready ($(ls /tmp/cilium/config-map | wc -l) keys)"

# ── 7. Clean stale state (replaces clean-cilium-state init container) ─
bashio::log.info "Cleaning stale Cilium state..."
export CILIUM_BPF_STATE=""       # Don't clean BPF on normal restart
export CILIUM_ALL_STATE=""       # Don't clean all state on normal restart
export WRITE_CNI_CONF_WHEN_READY=""
/usr/local/bin/cilium-init-container.sh 2>/dev/null || true

# ── 8. Kernel capability check ───────────────────────────────────
bashio::log.info "Checking kernel capabilities..."
if [ -f /sys/kernel/btf/vmlinux ]; then
    bashio::log.info "BTF available - CO-RE BPF programs supported"
else
    bashio::log.warning "BTF not available - legacy BPF probe mode"
fi
if modinfo wireguard > /dev/null 2>&1 || [ -d /sys/module/wireguard ]; then
    bashio::log.info "WireGuard kernel module available"
else
    bashio::log.warning "WireGuard module not found - encryption may fail"
fi

bashio::log.info "=== Init complete ==="
