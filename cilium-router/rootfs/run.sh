#!/bin/bash
set -euo pipefail
export PATH="/usr/sbin:/sbin:$PATH"

# ── Read addon options from /data/options.json ────────────────────
OPTIONS_FILE="/data/options.json"
KUBECONFIG_PATH=$(jq -r '.kubeconfig_path // "/config/kubeconfig"' "${OPTIONS_FILE}")
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

# ── 3. Host cgroup v2 (critical for socket LB) ──────────────────
# Inspired by the netdata HA addon approach: use nsenter into PID 1's
# mount namespace + docker CLI to mount host cgroup into our container
# from the outside, then restart ourselves so the mount is visible.
# See: https://github.com/felipecrs/netdata-hass-addon
CGROUP_ROOT="/run/cilium/cgroupv2"
CGROUP_MARKER="/var/run/cilium/.cgroup-mounted"

if [ -f "${CGROUP_MARKER}" ]; then
    echo "[init] Host cgroup already mounted from previous run"
else
    echo "[init] Mounting host cgroup v2 via nsenter + docker..."

    # Find our container ID from /proc/self/mountinfo
    CONTAINER_ID=$(sed -n 's|.*docker/containers/\([a-f0-9]*\)/.*|\1|p' /proc/self/mountinfo | head -1)
    if [ -z "${CONTAINER_ID}" ]; then
        # Fallback: try cgroup path
        CONTAINER_ID=$(sed -n 's|.*/docker-\([a-f0-9]*\)\.scope.*|\1|p' /proc/self/cgroup | head -1)
    fi

    if [ -n "${CONTAINER_ID}" ]; then
        echo "[init]   Container ID: ${CONTAINER_ID:0:12}"

        # Use Docker API via curl (docker CLI not in Cilium image)
        DOCKER_SOCK="/var/run/docker.sock"
        MERGED_DIR=$(curl -s --unix-socket "${DOCKER_SOCK}" \
            "http://localhost/containers/${CONTAINER_ID}/json" 2>/dev/null \
            | jq -r '.GraphDriver.Data.MergedDir // empty')

        if [ -n "${MERGED_DIR}" ]; then
            echo "[init]   Merged dir: ${MERGED_DIR}"

            # Use nsenter into host's mount namespace to bind-mount host cgroup
            # into our container's filesystem from the outside
            nsenter --target 1 --mount -- \
                mkdir -p "${MERGED_DIR}${CGROUP_ROOT}" 2>/dev/null

            nsenter --target 1 --mount -- \
                mount --bind /sys/fs/cgroup "${MERGED_DIR}${CGROUP_ROOT}" 2>&1 && {
                echo "[init]   Host cgroup mounted into container overlay"

                # Mark that we mounted it, then restart ourselves
                # so the mount becomes visible inside the container
                mkdir -p "$(dirname "${CGROUP_MARKER}")"
                touch "${CGROUP_MARKER}"

                echo "[init]   Restarting container to pick up the mount..."
                curl -s --unix-socket "${DOCKER_SOCK}" \
                    -X POST "http://localhost/containers/${CONTAINER_ID}/restart?t=5" &
                sleep 10
                exit 0
            } || {
                echo "[init]   WARNING: nsenter mount failed"
            }
        else
            echo "[init]   WARNING: Could not get container merged dir (Docker API response: $(curl -s --unix-socket "${DOCKER_SOCK}" "http://localhost/containers/${CONTAINER_ID}/json" 2>/dev/null | head -c 200))"
        fi
    else
        echo "[init]   WARNING: Could not determine container ID"
    fi

    # Fallback
    CGROUP_ROOT="/sys/fs/cgroup"
    echo "[init]   FALLBACK: Using container cgroup at ${CGROUP_ROOT}"
fi

# ── 4. Set sysctls ──────────────────────────────────────────────
echo "[init] Loading kernel modules..."
modprobe wireguard 2>/dev/null || echo "[init] WARNING: Failed to load wireguard module"
modprobe vxlan 2>/dev/null || true

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
# In our container, /proc IS the host proc (privileged + host_network)
printf '%s' "/proc" > /tmp/cilium/config-map/procfs
# Use the host's cgroup root determined in step 3
printf '%s' "${CGROUP_ROOT}" > /tmp/cilium/config-map/cgroup-root

# Create /host/proc symlink as safety net (some cilium code hardcodes /host/proc)
ln -sfn /proc /host/proc 2>/dev/null || true
ln -sfn /sys /host/sys 2>/dev/null || true

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
    --lib-dir=/var/lib/cilium
