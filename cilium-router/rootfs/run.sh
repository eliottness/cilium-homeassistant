#!/bin/bash
set -euo pipefail
export PATH="/usr/sbin:/sbin:$PATH"

# ── Read addon options from /data/options.json ────────────────────
OPTIONS_FILE="/data/options.json"
KUBECONFIG_PATH=$(jq -r '.kubeconfig_path // "/config/kubeconfig"' "${OPTIONS_FILE}")
NODE_NAME=$(jq -r '.node_name // "ha-cilium"' "${OPTIONS_FILE}")
LOG_LEVEL=$(jq -r '.log_level // "info"' "${OPTIONS_FILE}")
CILIUM_NAMESPACE=$(jq -r '.cilium_namespace // "kube-system"' "${OPTIONS_FILE}")

# ── Input validation ─────────────────────────────────────────────
if ! [[ "${NODE_NAME}" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]]; then
    echo "[init] FATAL: Invalid node_name '${NODE_NAME}'. Must be lowercase alphanumeric, hyphens, or dots."
    exit 1
fi
case "${KUBECONFIG_PATH}" in
    /config/*|/share/*|/ssl/*) ;;
    *) echo "[init] FATAL: kubeconfig_path must be under /config/, /share/, or /ssl/"; exit 1 ;;
esac

echo "[init] === Cilium Router Addon Init ==="

# ── 1. Kubeconfig ────────────────────────────────────────────────
if [ ! -f "${KUBECONFIG_PATH}" ]; then
    echo "[init] FATAL: Kubeconfig not found at ${KUBECONFIG_PATH}"
    exit 1
fi
mkdir -p /etc/cilium
cp "${KUBECONFIG_PATH}" /etc/cilium/kubeconfig
chmod 600 /etc/cilium/kubeconfig
export KUBECONFIG=/etc/cilium/kubeconfig

echo "[init] Testing cluster connectivity..."
for i in $(seq 1 5); do
    if kubectl cluster-info > /dev/null 2>&1; then
        echo "[init] Cluster connection OK"
        break
    fi
    if [ "$i" -eq 5 ]; then
        echo "[init] FATAL: Cannot connect to cluster after 5 attempts."
        exit 1
    fi
    echo "[init]   Attempt $i failed, retrying in $((i * 10))s..."
    sleep $((i * 10))
done

if ! kubectl auth can-i create nodes > /dev/null 2>&1; then
    echo "[init] WARNING: Kubeconfig may lack permissions to create Node objects."
fi

# ══════════════════════════════════════════════════════════════════
# Init containers — replicate exactly what the DaemonSet does.
# With host_pid:true, /proc is the host's /proc, so
# /proc/1/ns/* is the same as /hostproc/1/ns/* in the DaemonSet.
# ══════════════════════════════════════════════════════════════════

# ── 2. config (DaemonSet init container #1: "config") ────────────
echo "[init] config: fetching Cilium config from cluster..."
KUBERNETES_SERVICE_HOST="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' | sed 's|https\?://||;s|:.*||')"
KUBERNETES_SERVICE_PORT="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' | sed 's|.*:||')"
export K8S_NODE_NAME="${NODE_NAME}"
export CILIUM_K8S_NAMESPACE="${CILIUM_NAMESPACE}"
export KUBERNETES_SERVICE_HOST KUBERNETES_SERVICE_PORT

mkdir -p /tmp/cilium/config-map

cilium-dbg build-config \
    --k8s-kubeconfig-path=/etc/cilium/kubeconfig \
    --dest=/tmp/cilium/config-map \
    2>&1 || {
    echo "[init]   WARNING: build-config failed, falling back to manual ConfigMap dump..."
    kubectl get configmap cilium-config -n "${CILIUM_NAMESPACE}" -o json \
        | jq -r '.data | to_entries[] | "\(.key)\n\(.value)"' \
        | while IFS= read -r key && IFS= read -r value; do
            printf '%s' "${value}" > "/tmp/cilium/config-map/${key}"
        done
}

# Overrides for running without kubelet
printf '%s' "false" > /tmp/cilium/config-map/enable-l7-proxy
printf '%s' ""      > /tmp/cilium/config-map/write-cni-conf-when-ready
printf '%s' "false" > /tmp/cilium/config-map/enable-health-check-nodeport
printf '%s' "false" > /tmp/cilium/config-map/cni-exclusive
printf '%s' "/etc/cilium/kubeconfig" > /tmp/cilium/config-map/k8s-kubeconfig-path
printf '%s' "/proc" > /tmp/cilium/config-map/procfs
if [ "${LOG_LEVEL}" = "debug" ]; then
    printf '%s' "true" > /tmp/cilium/config-map/debug
fi

# Create /host/proc symlink (some cilium code hardcodes /host/proc)
ln -sfn /proc /host/proc 2>/dev/null || true
ln -sfn /sys /host/sys 2>/dev/null || true

echo "[init]   Config ready ($(ls /tmp/cilium/config-map | wc -l) keys)"

# ── 3. mount-cgroup (DaemonSet init container #2) ────────────────
# The DaemonSet copies the binary to a hostPath volume, then runs via nsenter.
# We copy to the host's /tmp via /proc/1/root/tmp (host_pid: true).
echo "[init] mount-cgroup: mounting cgroup2 on host..."
cp /usr/bin/cilium-mount /proc/1/root/tmp/cilium-mount
nsenter --cgroup=/proc/1/ns/cgroup --mount=/proc/1/ns/mnt \
    /tmp/cilium-mount /run/cilium/cgroupv2 2>&1 || \
    echo "[init]   WARNING: cilium-mount failed"
rm -f /proc/1/root/tmp/cilium-mount

# ── 4. apply-sysctl-overwrites (DaemonSet init container #3) ────
echo "[init] apply-sysctl-overwrites: applying sysctls on host..."
cp /usr/bin/cilium-sysctlfix /proc/1/root/tmp/cilium-sysctlfix
nsenter --mount=/proc/1/ns/mnt \
    /tmp/cilium-sysctlfix 2>&1 || \
    echo "[init]   WARNING: cilium-sysctlfix failed"
rm -f /proc/1/root/tmp/cilium-sysctlfix

# ── 5. mount-bpf-fs (DaemonSet init container #4) ───────────────
echo "[init] mount-bpf-fs: mounting BPF filesystem..."
if ! mount | grep -q '/sys/fs/bpf type bpf'; then
    mount -t bpf bpf /sys/fs/bpf || {
        echo "[init] FATAL: Failed to mount bpffs."
        exit 1
    }
fi

# ── 6. clean-cilium-state (DaemonSet init container #5) ─────────
echo "[init] clean-cilium-state: cleaning stale state..."
export CILIUM_ALL_STATE="$(cat /tmp/cilium/config-map/clean-cilium-state 2>/dev/null || echo '')"
export CILIUM_BPF_STATE="$(cat /tmp/cilium/config-map/clean-cilium-bpf-state 2>/dev/null || echo '')"
export WRITE_CNI_CONF_WHEN_READY=""
/init-container.sh 2>&1 || echo "[init]   WARNING: clean-cilium-state failed (non-fatal)"

# Remount /proc/sys rw (Docker mounts it ro, cilium-agent needs to write sysctls)
mount -o remount,rw /proc/sys 2>/dev/null || \
    echo "[init] WARNING: Failed to remount /proc/sys rw"

# ── 7. Create Node object (MANDATORY: CiliumNode OwnerReference) ─
echo "[init] Creating/updating Node '${NODE_NAME}'..."
NODE_IP=$(ip route get "${KUBERNETES_SERVICE_HOST}" 2>/dev/null | awk '{print $7; exit}' || ip route get 1.1.1.1 | awk '{print $7; exit}')
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
      \"kubeletVersion\": \"v0.1.0-cilium-router\"
    }
  }
}" 2>/dev/null || true
echo "[init] Node '${NODE_NAME}' ready at ${NODE_IP}"

# ── 8. Kernel check ─────────────────────────────────────────────
if [ -f /sys/kernel/btf/vmlinux ]; then
    echo "[init] BTF available"
else
    echo "[init] WARNING: BTF not available - legacy BPF probe mode"
fi
if [ -d /sys/module/wireguard ]; then
    echo "[init] WireGuard module loaded"
else
    echo "[init] WARNING: WireGuard module not found"
fi

echo "[init] === Init complete, starting services ==="

# ── Cleanup on exit ──────────────────────────────────────────────
cleanup() {
    echo "[cleanup] Stopping — cleaning up cluster resources..."
    kubectl delete node "${NODE_NAME}" --ignore-not-found 2>/dev/null || true
    kubectl delete lease "${NODE_NAME}" -n kube-node-lease --ignore-not-found 2>/dev/null || true
    kill $(jobs -p) 2>/dev/null || true
    echo "[cleanup] Done"
}
trap cleanup SIGTERM SIGINT EXIT

# ── Node heartbeat ───────────────────────────────────────────────
HEARTBEAT_FAILURES=0
(
    while true; do
        TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
        if kubectl patch lease "${NODE_NAME}" -n kube-node-lease \
            --type=merge \
            -p "{\"spec\":{\"renewTime\":\"${TIMESTAMP}\"}}" \
            2>/dev/null; then
            HEARTBEAT_FAILURES=0
        else
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
            HEARTBEAT_FAILURES=$((HEARTBEAT_FAILURES + 1))
            if [ $((HEARTBEAT_FAILURES % 6)) -eq 0 ]; then
                echo "[heartbeat] WARNING: ${HEARTBEAT_FAILURES} consecutive failures" >&2
            fi
        fi
        kubectl patch node "${NODE_NAME}" --type=merge --subresource=status \
            -p "{\"status\":{\"conditions\":[{\"type\":\"Ready\",\"status\":\"True\",\"lastHeartbeatTime\":\"${TIMESTAMP}\",\"lastTransitionTime\":\"${TIMESTAMP}\",\"reason\":\"CiliumRouterRunning\",\"message\":\"Cilium agent running\"}]}}" \
            2>/dev/null || true
        sleep 10
    done
) &
echo "[heartbeat] Started (PID $!)"

# ── cilium-agent (DaemonSet main container) ──────────────────────
# Matches: cilium-agent --config-dir=/tmp/cilium/config-map
echo "[agent] Starting cilium-agent as node '${NODE_NAME}'..."

cilium-agent \
    --config-dir=/tmp/cilium/config-map \
    --bpf-root=/sys/fs/bpf \
    --state-dir=/var/run/cilium \
    --lib-dir=/var/lib/cilium &
AGENT_PID=$!

wait ${AGENT_PID}
