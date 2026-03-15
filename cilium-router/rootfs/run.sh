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
# The DaemonSet uses nsenter to mount cgroup2 ON THE HOST, then a hostPath
# volume to access it. We replicate: nsenter to mount on host, then
# bind-mount /proc/1/root/... into our namespace.
CGROUP_ROOT="/run/cilium/cgroupv2"
mkdir -p "${CGROUP_ROOT}"

echo "[init] Step 3a: Creating cgroup2 mount on HOST via nsenter..."
# Create directory on the HOST (not just in the container)
nsenter --cgroup=/proc/1/ns/cgroup --mount=/proc/1/ns/mnt -- \
    mkdir -p /run/cilium/cgroupv2 2>&1 || echo "[init]   mkdir on host failed (may already exist)"

# Mount cgroup2 on the HOST if not already mounted
nsenter --cgroup=/proc/1/ns/cgroup --mount=/proc/1/ns/mnt -- \
    sh -c 'mount | grep -q "/run/cilium/cgroupv2 type cgroup2" || mount -t cgroup2 none /run/cilium/cgroupv2' 2>&1 || {
    echo "[init]   mount via sh failed, trying cilium-mount..."
    nsenter --cgroup=/proc/1/ns/cgroup --mount=/proc/1/ns/mnt -- \
        /usr/bin/cilium-mount /run/cilium/cgroupv2 2>&1 || echo "[init]   cilium-mount also failed"
}

echo "[init] Step 3b: Bind-mounting host cgroup2 into container..."
# Bind-mount the HOST's cgroup2 into our mount namespace
if mount --bind /proc/1/root/run/cilium/cgroupv2 /run/cilium/cgroupv2 2>&1; then
    echo "[init] Host cgroup2 bind-mounted at ${CGROUP_ROOT}"
    # Verify it's the host's root cgroup (should have many subdirs)
    echo "[init]   Contents: $(ls /run/cilium/cgroupv2/ 2>/dev/null | head -10)"
else
    echo "[init] WARNING: Bind-mount failed. Trying direct /proc/1/root path..."
    if [ -d /proc/1/root/sys/fs/cgroup/system.slice ]; then
        CGROUP_ROOT="/proc/1/root/sys/fs/cgroup"
        echo "[init]   Using ${CGROUP_ROOT} (host cgroup via procfs)"
    else
        CGROUP_ROOT="/sys/fs/cgroup"
        echo "[init]   FALLBACK: Using container cgroup. ClusterIP services will NOT work outside this container."
    fi
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

# ── 9. iptables service DNAT (workaround: cgroup socket LB can't reach host) ─
# The HA Supervisor blocks /proc/1/ns/cgroup access, so BPF socket LB only
# works inside this container. As a workaround, we generate iptables DNAT
# rules for ClusterIP services so host processes can reach them.
(
    sleep 60  # wait for agent to sync services
    echo "[svc-sync] === Starting iptables service sync ==="
    # Create a custom chain for our rules
    iptables -t nat -N CILIUM_HA_SERVICES 2>/dev/null || iptables -t nat -F CILIUM_HA_SERVICES
    # OUTPUT: locally-originated traffic (from host processes)
    iptables -t nat -C OUTPUT -j CILIUM_HA_SERVICES 2>/dev/null || \
        iptables -t nat -I OUTPUT -j CILIUM_HA_SERVICES
    # PREROUTING: traffic from other containers (Docker bridge → host)
    iptables -t nat -C PREROUTING -j CILIUM_HA_SERVICES 2>/dev/null || \
        iptables -t nat -I PREROUTING -j CILIUM_HA_SERVICES

    while true; do
        # Get service list from cilium and generate DNAT rules
        RULES_FILE=$(mktemp)
        cilium-dbg service list 2>/dev/null | grep "ClusterIP" | while IFS= read -r line; do
            # Parse: ID  frontend_ip:port/proto  ClusterIP  N => backend_ip:port/proto (active)
            # Fields: $1=ID $2=frontend $3=type $4=count $5==> $6=backend
            FRONTEND=$(echo "$line" | awk '{print $2}')
            BACKEND=$(echo "$line" | awk '{print $6}')
            [ -z "$FRONTEND" ] || [ -z "$BACKEND" ] && continue

            SVC_IP=$(echo "$FRONTEND" | cut -d: -f1)
            SVC_PORT=$(echo "$FRONTEND" | cut -d: -f2 | cut -d/ -f1)
            PROTO=$(echo "$FRONTEND" | grep -o '/[A-Z]*' | tr -d '/' | tr 'A-Z' 'a-z')
            BACK_IP=$(echo "$BACKEND" | cut -d: -f1)
            BACK_PORT=$(echo "$BACKEND" | cut -d: -f2 | cut -d/ -f1)

            [ -z "$SVC_IP" ] || [ -z "$SVC_PORT" ] || [ -z "$PROTO" ] || [ -z "$BACK_IP" ] || [ -z "$BACK_PORT" ] && continue
            echo "-A CILIUM_HA_SERVICES -d ${SVC_IP}/32 -p ${PROTO} --dport ${SVC_PORT} -j DNAT --to-destination ${BACK_IP}:${BACK_PORT}" >> "$RULES_FILE"
        done

        # Debug: show first parsed rule
        if [ -s "$RULES_FILE" ]; then
            echo "[svc-sync] First rule: $(head -1 "$RULES_FILE")"
        else
            echo "[svc-sync] WARNING: No rules generated. Service count: $(cilium-dbg service list 2>/dev/null | grep -c ClusterIP)"
        fi

        # Atomically replace rules
        RULE_COUNT=$(wc -l < "$RULES_FILE" 2>/dev/null || echo 0)
        iptables -t nat -F CILIUM_HA_SERVICES 2>/dev/null
        if [ "$RULE_COUNT" -gt 0 ]; then
            while IFS= read -r rule; do
                iptables -t nat $rule 2>/dev/null
            done < "$RULES_FILE"
            echo "[svc-sync] Synced ${RULE_COUNT} iptables DNAT rules for ClusterIP services"
        fi
        rm -f "$RULES_FILE"

        sleep 30  # resync every 30s
    done
) &
echo "[svc-sync] Service iptables sync started in background"

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
