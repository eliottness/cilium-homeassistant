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
# CRITICAL-3: Validate node name (must be a valid DNS subdomain)
if ! [[ "${NODE_NAME}" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]]; then
    echo "[init] FATAL: Invalid node_name '${NODE_NAME}'. Must be lowercase alphanumeric, hyphens, or dots."
    exit 1
fi

# HIGH-6: Validate kubeconfig path is within allowed directories
case "${KUBECONFIG_PATH}" in
    /config/*|/share/*|/ssl/*) ;;
    *) echo "[init] FATAL: kubeconfig_path must be under /config/, /share/, or /ssl/"; exit 1 ;;
esac

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

# MEDIUM-3: Retry cluster connectivity with backoff
echo "[init] Testing cluster connectivity..."
for i in $(seq 1 5); do
    if kubectl cluster-info > /dev/null 2>&1; then
        echo "[init] Cluster connection OK"
        break
    fi
    if [ "$i" -eq 5 ]; then
        echo "[init] FATAL: Cannot connect to cluster after 5 attempts. Check kubeconfig."
        exit 1
    fi
    echo "[init]   Attempt $i failed, retrying in $((i * 10))s..."
    sleep $((i * 10))
done

# HIGH-7: Check RBAC permissions
if ! kubectl auth can-i create nodes > /dev/null 2>&1; then
    echo "[init] WARNING: Kubeconfig may lack permissions to create Node objects."
fi

# ── 2. Remount /proc/sys read-write (Docker mounts it ro by default) ──
echo "[init] Remounting /proc/sys read-write..."
mount -o remount,rw /proc/sys 2>/dev/null || \
    echo "[init] WARNING: Failed to remount /proc/sys rw"

# ── 3. Mount BPF filesystem ─────────────────────────────────────
if ! mount | grep -q '/sys/fs/bpf type bpf'; then
    echo "[init] Mounting BPF filesystem..."
    mount -t bpf bpf /sys/fs/bpf || {
        echo "[init] FATAL: Failed to mount bpffs. Kernel BPF support missing?"
        exit 1
    }
fi

# ── 4. Cgroup v2 ────────────────────────────────────────────────
# HAOS blocks nsenter into PID 1's namespaces (Permission denied on
# /proc/1/ns/mnt and /proc/1/ns/cgroup). Without --cgroupns=host from
# the Docker daemon, we cannot attach BPF socket LB to the host's cgroup.
# See: https://github.com/orgs/home-assistant/discussions/3203
CGROUP_ROOT="/sys/fs/cgroup"

# ── 5. Set sysctls ──────────────────────────────────────────────
echo "[init] Loading kernel modules..."
modprobe wireguard 2>/dev/null || echo "[init] WARNING: Failed to load wireguard module"
modprobe vxlan 2>/dev/null || true

echo "[init] Configuring sysctls..."
sysctl -w net.ipv4.ip_forward=1 2>/dev/null || true
sysctl -w net.ipv4.conf.all.forwarding=1 2>/dev/null || true
sysctl -w net.core.bpf_jit_enable=1 2>/dev/null || true
sysctl -w net.ipv4.conf.all.rp_filter=0 2>/dev/null || true
sysctl -w net.ipv4.conf.default.rp_filter=0 2>/dev/null || true

# MEDIUM-9: Verify critical sysctl was applied
if [ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null)" != "1" ]; then
    echo "[init] FATAL: ip_forward could not be enabled. Routing will not work."
    exit 1
fi

# ── 6. Create Node object (MANDATORY: CiliumNode OwnerReference) ─
echo "[init] Creating/updating Node '${NODE_NAME}'..."
# MEDIUM-2: Use API server IP as route target instead of 1.1.1.1
KUBERNETES_SERVICE_HOST="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' | sed 's|https\?://||;s|:.*||')"
KUBERNETES_SERVICE_PORT="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' | sed 's|.*:||')"
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

# ── 7. Build config ─────────────────────────────────────────────
echo "[init] Fetching Cilium config from cluster..."
export K8S_NODE_NAME="${NODE_NAME}"
export CILIUM_K8S_NAMESPACE="${CILIUM_NAMESPACE}"
export KUBERNETES_SERVICE_HOST KUBERNETES_SERVICE_PORT

mkdir -p /tmp/cilium/config-map

cilium-dbg build-config \
    --k8s-kubeconfig-path=/etc/cilium/kubeconfig \
    --dest=/tmp/cilium/config-map \
    2>&1 || {
    echo "[init] WARNING: cilium-dbg build-config failed, falling back to manual ConfigMap dump..."
    kubectl get configmap cilium-config -n "${CILIUM_NAMESPACE}" -o json \
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
# Enable ClusterIP access via TC/XDP datapath (only on THIS node, not cluster-wide)
printf '%s' "true"  > /tmp/cilium/config-map/bpf-lb-external-clusterip
# In our container, /proc IS the host proc (privileged + host_network)
printf '%s' "/proc" > /tmp/cilium/config-map/procfs
printf '%s' "${CGROUP_ROOT}" > /tmp/cilium/config-map/cgroup-root
# HIGH-3: Apply log level
if [ "${LOG_LEVEL}" = "debug" ]; then
    printf '%s' "true" > /tmp/cilium/config-map/debug
fi

# Create /host/proc symlink as safety net (some cilium code hardcodes /host/proc)
ln -sfn /proc /host/proc 2>/dev/null || true
ln -sfn /sys /host/sys 2>/dev/null || true

echo "[init] Config ready ($(ls /tmp/cilium/config-map | wc -l) keys)"

# ── 8. Clean stale state ────────────────────────────────────────
echo "[init] Cleaning stale Cilium state..."
export CILIUM_BPF_STATE="" CILIUM_ALL_STATE="" WRITE_CNI_CONF_WHEN_READY=""
# MEDIUM-7: Log errors instead of silencing
/usr/local/bin/cilium-init-container.sh 2>&1 || echo "[init] WARNING: cilium-init-container.sh failed (non-fatal)"

# ── 9. Kernel capability check ──────────────────────────────────
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

# ── CRITICAL-2: Cleanup on exit ──────────────────────────────────
cleanup() {
    echo "[cleanup] Stopping — cleaning up cluster resources..."
    kubectl delete node "${NODE_NAME}" --ignore-not-found 2>/dev/null || true
    kubectl delete lease "${NODE_NAME}" -n kube-node-lease --ignore-not-found 2>/dev/null || true
    kill $(jobs -p) 2>/dev/null || true
    echo "[cleanup] Done"
}
trap cleanup SIGTERM SIGINT EXIT

# ── Start node heartbeat in background ───────────────────────────
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
            # Try creating the lease if it doesn't exist
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
            # MEDIUM-5: Log periodic warnings on failure
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
HEARTBEAT_PID=$!
echo "[heartbeat] Node heartbeat started (PID ${HEARTBEAT_PID})"

# ── Start cilium-agent (foreground, no exec — so trap works) ─────
echo "[agent] Starting cilium-agent as node '${NODE_NAME}'..."

# HIGH-4: Don't use exec — run in foreground so trap cleanup fires on exit
cilium-agent \
    --config-dir=/tmp/cilium/config-map \
    --bpf-root=/sys/fs/bpf \
    --state-dir=/var/run/cilium \
    --lib-dir=/var/lib/cilium &
AGENT_PID=$!

# Wait for agent to exit, then cleanup runs via trap
wait ${AGENT_PID}
