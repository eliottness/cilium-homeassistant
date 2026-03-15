#!/bin/bash
set -euo pipefail

# ── Read addon options from /data/options.json ────────────────────
OPTIONS_FILE="/data/options.json"
KUBECONFIG_PATH=$(jq -r '.kubeconfig_path // "/share/cilium/kubeconfig"' "${OPTIONS_FILE}")
NODE_NAME=$(jq -r '.node_name // "ha-cilium"' "${OPTIONS_FILE}")
LOG_LEVEL=$(jq -r '.log_level // "info"' "${OPTIONS_FILE}")

echo "[init] === Cilium Router Addon Init ==="

# ── 1. Copy kubeconfig from file path ────────────────────────────
if [ ! -f "${KUBECONFIG_PATH}" ]; then
    echo "[init] FATAL: Kubeconfig not found at ${KUBECONFIG_PATH}"
    echo "[init] Place your kubeconfig file there via Samba, SSH, or File Editor addon."
    exit 1
fi
mkdir -p /etc/cilium
cp "${KUBECONFIG_PATH}" /etc/cilium/kubeconfig
chmod 600 /etc/cilium/kubeconfig
export KUBECONFIG=/etc/cilium/kubeconfig

echo "[init] Testing cluster connectivity..."
if ! kubectl cluster-info > /dev/null 2>&1; then
    echo "[init] FATAL: Cannot connect to cluster. Check kubeconfig."
    exit 1
fi
echo "[init] Cluster connection OK"

# ── 2. Mount BPF filesystem ─────────────────────────────────────
if ! mount | grep -q '/sys/fs/bpf type bpf'; then
    echo "[init] Mounting BPF filesystem..."
    mount -t bpf bpf /sys/fs/bpf || {
        echo "[init] FATAL: Failed to mount bpffs. Kernel BPF support missing?"
        exit 1
    }
fi

# ── 3. Mount cgroup v2 ──────────────────────────────────────────
mkdir -p /run/cilium/cgroupv2
if ! mount | grep -q '/run/cilium/cgroupv2 type cgroup2'; then
    echo "[init] Mounting cgroup v2..."
    mount -t cgroup2 none /run/cilium/cgroupv2 2>/dev/null || \
        echo "[init] WARNING: cgroup2 mount failed (may already be available)"
fi

# ── 4. Set sysctls ──────────────────────────────────────────────
echo "[init] Configuring sysctls..."
sysctl -w net.ipv4.ip_forward=1 2>/dev/null || true
sysctl -w net.ipv4.conf.all.forwarding=1 2>/dev/null || true
sysctl -w net.core.bpf_jit_enable=1 2>/dev/null || true
sysctl -w net.ipv4.conf.all.rp_filter=0 2>/dev/null || true
sysctl -w net.ipv4.conf.default.rp_filter=0 2>/dev/null || true

# ── 5. Create Node object (MANDATORY: CiliumNode OwnerReference) ─
echo "[init] Creating/updating Node '${NODE_NAME}'..."
NODE_IP=$(ip route get 1.1.1.1 | awk '{print $7; exit}')
ARCH=$(uname -m)
[ "$ARCH" = "aarch64" ] && ARCH="arm64"
[ "$ARCH" = "x86_64" ] && ARCH="amd64"

if ! kubectl get node "${NODE_NAME}" > /dev/null 2>&1; then
    echo "[init] Creating Node '${NODE_NAME}' at ${NODE_IP}..."
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Node
metadata:
  name: ${NODE_NAME}
  labels:
    kubernetes.io/hostname: ${NODE_NAME}
    kubernetes.io/os: linux
    kubernetes.io/arch: ${ARCH}
    node-role.kubernetes.io/cilium-router: ""
  annotations:
    node.alpha.kubernetes.io/ttl: "0"
spec:
  taints:
    - key: "node-role.kubernetes.io/cilium-router"
      value: "true"
      effect: "NoSchedule"
    - key: "node-role.kubernetes.io/cilium-router"
      value: "true"
      effect: "NoExecute"
EOF
fi

TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
kubectl patch node "${NODE_NAME}" --type=merge --subresource=status \
    -p "{
  \"status\": {
    \"addresses\": [
      {\"type\": \"InternalIP\", \"address\": \"${NODE_IP}\"},
      {\"type\": \"Hostname\", \"address\": \"${NODE_NAME}\"}
    ],
    \"conditions\": [{
      \"type\": \"Ready\", \"status\": \"True\",
      \"lastHeartbeatTime\": \"${TIMESTAMP}\", \"lastTransitionTime\": \"${TIMESTAMP}\",
      \"reason\": \"CiliumRouterReady\", \"message\": \"Cilium router addon running\"
    }],
    \"nodeInfo\": {
      \"operatingSystem\": \"linux\", \"architecture\": \"${ARCH}\",
      \"kubeletVersion\": \"v0.0.0-cilium-router\"
    }
  }
}" 2>/dev/null || true
echo "[init] Node '${NODE_NAME}' ready at ${NODE_IP}"

# ── 6. Build config ─────────────────────────────────────────────
echo "[init] Fetching Cilium config from cluster..."
export K8S_NODE_NAME="${NODE_NAME}"
export CILIUM_K8S_NAMESPACE="kube-system"
export KUBERNETES_SERVICE_HOST="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' | sed 's|https\?://||;s|:.*||')"
export KUBERNETES_SERVICE_PORT="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' | sed 's|.*:||')"

mkdir -p /tmp/cilium/config-map

cilium-dbg build-config \
    --k8s-kubeconfig-path=/etc/cilium/kubeconfig \
    --dest=/tmp/cilium/config-map \
    2>&1 || {
    echo "[init] WARNING: cilium-dbg build-config failed, falling back to manual ConfigMap dump..."
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
printf '%s' "/etc/cilium/kubeconfig" > /tmp/cilium/config-map/k8s-kubeconfig-path

echo "[init] Config ready ($(ls /tmp/cilium/config-map | wc -l) keys)"

# ── 7. Clean stale state ────────────────────────────────────────
echo "[init] Cleaning stale Cilium state..."
export CILIUM_BPF_STATE="" CILIUM_ALL_STATE="" WRITE_CNI_CONF_WHEN_READY=""
/usr/local/bin/cilium-init-container.sh 2>/dev/null || true

# ── 8. Kernel capability check ──────────────────────────────────
if [ -f /sys/kernel/btf/vmlinux ]; then
    echo "[init] BTF available - CO-RE BPF programs supported"
else
    echo "[init] WARNING: BTF not available - legacy BPF probe mode"
fi
if modinfo wireguard > /dev/null 2>&1 || [ -d /sys/module/wireguard ]; then
    echo "[init] WireGuard kernel module available"
else
    echo "[init] WARNING: WireGuard module not found - encryption may fail"
fi

echo "[init] === Init complete, starting services ==="

# ── Start node heartbeat in background ───────────────────────────
(
    while true; do
        TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
        kubectl patch lease "${NODE_NAME}" -n kube-node-lease \
            --type=merge \
            -p "{\"spec\":{\"renewTime\":\"${TIMESTAMP}\"}}" \
            2>/dev/null || \
        kubectl create -f - <<EOLEASE 2>/dev/null || true
apiVersion: coordination.k8s.io/v1
kind: Lease
metadata:
  name: ${NODE_NAME}
  namespace: kube-node-lease
spec:
  holderIdentity: ${NODE_NAME}
  leaseDurationSeconds: 40
  renewTime: "${TIMESTAMP}"
EOLEASE
        kubectl patch node "${NODE_NAME}" --type=merge --subresource=status \
            -p "{\"status\":{\"conditions\":[{\"type\":\"Ready\",\"status\":\"True\",\"lastHeartbeatTime\":\"${TIMESTAMP}\",\"lastTransitionTime\":\"${TIMESTAMP}\",\"reason\":\"CiliumRouterRunning\",\"message\":\"Cilium agent running\"}]}}" \
            2>/dev/null || true
        sleep 10
    done
) &
echo "[heartbeat] Node heartbeat started (PID $!)"

# ── Start cilium-agent (foreground) ──────────────────────────────
echo "[agent] Starting cilium-agent as node '${NODE_NAME}'..."
echo "[agent] API server: ${KUBERNETES_SERVICE_HOST}:${KUBERNETES_SERVICE_PORT}"

exec cilium-agent \
    --config-dir=/tmp/cilium/config-map \
    --bpf-root=/sys/fs/bpf \
    --state-dir=/var/run/cilium \
    --lib-dir=/var/lib/cilium \
    --log-driver=syslog \
    --log-opt="level=${LOG_LEVEL}"
