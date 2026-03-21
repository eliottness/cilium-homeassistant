# Plan: Cilium Router Home Assistant Addon

## Overview

Build a Home Assistant addon that runs `cilium-agent` (from `quay.io/cilium/cilium:v1.19.0`) to make the Home Assistant Green participate in the Cilium network as a routing node. The addon connects to the k3s cluster API via a user-provided kubeconfig. No kubelet involved — cilium-agent talks directly to the K8s API.

**Goal:** Route packets from the HA machine to any pod in the cluster, via Cilium's WireGuard + VXLAN tunnels.

**Key constraint:** Cilium 1.19 uses double encapsulation (VXLAN inside WireGuard). Only cilium-agent can handle this.

**Cluster context** (from `values.yaml`):
- cluster: `ardoines` (id: 2), clustermesh to `softalys`
- `routingMode: tunnel`, `encryption: wireguard`, `nodeEncryption: true`
- `kubeProxyReplacement: true`, `ipam: cluster-pool` (CIDR: `10.84.0.0/16`)
- API server: `192.168.1.37:6443`

## Critical Source Code Finding

**CiliumNode OwnerReference** (`pkg/nodediscovery/nodediscovery.go:304-309`): The agent unconditionally sets an OwnerReference on the CiliumNode pointing to the K8s `v1/Node`. Without a real Node object (with a UID), Kubernetes garbage-collects the CiliumNode. **Creating a K8s Node object is mandatory.**

**Good news** (`daemon/k8s/init.go:94-156`): `WaitForNodeInformation()` times out gracefully after 10s if `k8s-require-ipv4-pod-cidr=false` (the default). With `ipam: cluster-pool`, the CIDR comes from CiliumNode (allocated by the operator), not from `Node.spec.podCIDR`.

## Architecture

```
Home Assistant Green (aarch64, HAOS)
├── HA Supervisor (Docker)
│   └── cilium-router addon (privileged, host_network, host_pid)
│       ├── Init (cont-init.d/cilium-init.sh):
│       │   ├── Mount /sys/fs/bpf + cgroup v2
│       │   ├── Set sysctls (ip_forward, bpf_jit, rp_filter)
│       │   ├── kubectl create Node "ha-cilium" (tainted NoSchedule+NoExecute)
│       │   ├── cilium-dbg build-config (fetches real cilium-config ConfigMap)
│       │   └── /init-container.sh (clean stale BPF state)
│       │
│       ├── Service: cilium-agent
│       │   └── cilium-agent --config-dir=/tmp/cilium/config-map
│       │       ├── Creates CiliumNode with OwnerRef → Node (auto)
│       │       ├── Publishes WireGuard public key (auto)
│       │       ├── Sets up cilium_wg0 + cilium_vxlan (auto)
│       │       └── Installs BPF programs for routing (auto)
│       │
│       └── Service: node-heartbeat
│           └── Patches Node lease every 10s (keeps node "Ready")
│
├── cilium_wg0 (WireGuard, UDP 51871)
├── cilium_vxlan (VXLAN, UDP 8472)
└── BPF programs on host network interfaces
```

## File Structure

```
cilium-homeassistant/
├── repository.yaml
└── cilium-router/
    ├── config.yaml
    ├── build.yaml
    ├── Dockerfile
    └── rootfs/
        ├── etc/
        │   ├── cont-init.d/
        │   │   └── cilium-init.sh
        │   └── services.d/
        │       ├── cilium-agent/
        │       │   ├── run
        │       │   └── finish
        │       └── node-heartbeat/
        │           └── run
        └── usr/local/bin/
            └── create-node.sh
```

## Implementation Details

### Step 1: repository.yaml

```yaml
name: "Cilium Router for Home Assistant"
url: "https://github.com/DataDog/cilium-homeassistant"
maintainer: "Eliott Bouhana"
```

### Step 2: config.yaml

```yaml
name: "Cilium Router"
version: "0.1.0"
slug: "cilium_router"
description: "Routes traffic to Kubernetes pods via Cilium agent"
url: "https://github.com/DataDog/cilium-homeassistant"
arch:
  - aarch64
  - amd64
startup: "system"
boot: "manual"
init: true

# Full network + BPF access (matches DaemonSet security context)
host_network: true
host_pid: true
privileged:
  - NET_ADMIN
  - NET_RAW
  - SYS_ADMIN
  - SYS_MODULE
  - SYS_RESOURCE
  - DAC_READ_SEARCH
apparmor: false
full_access: true   # Needed for /sys/fs/bpf, /lib/modules, /proc/sys

map:
  - share:rw        # For kubeconfig file

options:
  kubeconfig_path: "/share/cilium/kubeconfig"
  node_name: "ha-cilium"
  log_level: "info"

schema:
  kubeconfig_path: str
  node_name: str
  log_level: "list(info|debug|warning|error)"
```

### Step 3: build.yaml

```yaml
build_from:
  aarch64: "ghcr.io/home-assistant/aarch64-base-debian:bookworm"
  amd64: "ghcr.io/home-assistant/amd64-base-debian:bookworm"
args:
  CILIUM_VERSION: "1.19.0"
```

### Step 4: Dockerfile

```dockerfile
# Stage 1: Cilium binaries from official image
ARG CILIUM_VERSION=1.19.0
FROM quay.io/cilium/cilium:v${CILIUM_VERSION} AS cilium

# Stage 2: kubectl
FROM bitnami/kubectl:1.31 AS kubectl

# Stage 3: Addon
ARG BUILD_FROM
FROM ${BUILD_FROM}

RUN apt-get update && apt-get install -y --no-install-recommends \
    bash curl jq iproute2 iptables ip6tables ipset kmod \
    libelf1 mount wireguard-tools ca-certificates \
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

# kubectl
COPY --from=kubectl /opt/bitnami/kubectl/bin/kubectl /usr/bin/

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
```

### Step 5: cilium-init.sh

```bash
#!/usr/bin/with-contenv bashio
set -euo pipefail

bashio::log.info "=== Cilium Router Addon Init ==="

KUBECONFIG_PATH=$(bashio::config 'kubeconfig_path')
NODE_NAME=$(bashio::config 'node_name')

# ── 1. Validate kubeconfig ───────────────────────────────────────
if [ ! -f "${KUBECONFIG_PATH}" ]; then
    bashio::log.fatal "Kubeconfig not found at ${KUBECONFIG_PATH}"
    bashio::log.fatal "Place it there via the Samba or SSH addon."
    exit 1
fi
cp "${KUBECONFIG_PATH}" /etc/cilium/kubeconfig
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
```

### Step 6: create-node.sh

```bash
#!/bin/bash
set -euo pipefail

export KUBECONFIG=/etc/cilium/kubeconfig
NODE_NAME=$(bashio::config 'node_name' 2>/dev/null || echo "ha-cilium")
NODE_IP=$(ip route get 1.1.1.1 | awk '{print $7; exit}')
ARCH=$(uname -m)
[ "$ARCH" = "aarch64" ] && ARCH="arm64"
[ "$ARCH" = "x86_64" ] && ARCH="amd64"

if kubectl get node "${NODE_NAME}" > /dev/null 2>&1; then
    bashio::log.info "Node '${NODE_NAME}' already exists"
else
    bashio::log.info "Creating Node '${NODE_NAME}' at ${NODE_IP}..."
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

# Always update the status (addresses, Ready condition)
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
kubectl patch node "${NODE_NAME}" \
    --type=merge \
    --subresource=status \
    -p "{
  \"status\": {
    \"addresses\": [
      {\"type\": \"InternalIP\", \"address\": \"${NODE_IP}\"},
      {\"type\": \"Hostname\", \"address\": \"${NODE_NAME}\"}
    ],
    \"conditions\": [{
      \"type\": \"Ready\",
      \"status\": \"True\",
      \"lastHeartbeatTime\": \"${TIMESTAMP}\",
      \"lastTransitionTime\": \"${TIMESTAMP}\",
      \"reason\": \"CiliumRouterReady\",
      \"message\": \"Cilium router addon running\"
    }],
    \"nodeInfo\": {
      \"operatingSystem\": \"linux\",
      \"architecture\": \"${ARCH}\",
      \"kubeletVersion\": \"v0.0.0-cilium-router\"
    }
  }
}" 2>/dev/null || true

bashio::log.info "Node '${NODE_NAME}' ready at ${NODE_IP}"
```

### Step 7: cilium-agent service

**rootfs/etc/services.d/cilium-agent/run:**
```bash
#!/usr/bin/with-contenv bashio

NODE_NAME=$(bashio::config 'node_name')
LOG_LEVEL=$(bashio::config 'log_level')

# Environment the agent expects (from DaemonSet template)
export K8S_NODE_NAME="${NODE_NAME}"
export CILIUM_K8S_NAMESPACE="kube-system"
# API server coordinates (from values.yaml k8sServiceHost/Port)
export KUBERNETES_SERVICE_HOST="$(cat /tmp/cilium/config-map/k8s-service-host 2>/dev/null || echo '192.168.1.37')"
export KUBERNETES_SERVICE_PORT="$(cat /tmp/cilium/config-map/k8s-service-port 2>/dev/null || echo '6443')"

bashio::log.info "Starting cilium-agent as node '${NODE_NAME}'..."
bashio::log.info "  API server: ${KUBERNETES_SERVICE_HOST}:${KUBERNETES_SERVICE_PORT}"

# --config-dir contains the real cilium-config ConfigMap (from build-config)
# plus our minimal overrides. The agent reads all config from there.
exec cilium-agent \
    --config-dir=/tmp/cilium/config-map \
    --bpf-root=/sys/fs/bpf \
    --state-dir=/var/run/cilium \
    --lib-dir=/var/lib/cilium \
    --log-driver=syslog \
    --log-opt="level=${LOG_LEVEL}"
```

**rootfs/etc/services.d/cilium-agent/finish:**
```bash
#!/usr/bin/with-contenv bashio
bashio::log.warning "cilium-agent stopped (exit code: ${1})"
```

### Step 8: node-heartbeat service

**rootfs/etc/services.d/node-heartbeat/run:**
```bash
#!/usr/bin/with-contenv bashio

export KUBECONFIG=/etc/cilium/kubeconfig
NODE_NAME=$(bashio::config 'node_name')

bashio::log.info "Starting node heartbeat for '${NODE_NAME}'..."

while true; do
    TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    # Update node lease (keeps node "Ready")
    kubectl patch lease "${NODE_NAME}" -n kube-node-lease \
        --type=merge \
        -p "{\"spec\":{\"renewTime\":\"${TIMESTAMP}\"}}" \
        2>/dev/null || \
    kubectl create -f - <<EOF 2>/dev/null || true
apiVersion: coordination.k8s.io/v1
kind: Lease
metadata:
  name: ${NODE_NAME}
  namespace: kube-node-lease
spec:
  holderIdentity: ${NODE_NAME}
  leaseDurationSeconds: 40
  renewTime: "${TIMESTAMP}"
EOF

    # Update node Ready condition
    kubectl patch node "${NODE_NAME}" --type=merge --subresource=status \
        -p "{\"status\":{\"conditions\":[{\"type\":\"Ready\",\"status\":\"True\",\"lastHeartbeatTime\":\"${TIMESTAMP}\",\"lastTransitionTime\":\"${TIMESTAMP}\",\"reason\":\"CiliumRouterRunning\",\"message\":\"Cilium agent running\"}]}}" \
        2>/dev/null || true

    sleep 10
done
```

## Volume Mapping

These are the volumes the DaemonSet mounts. In the HA addon, they map via Docker's `--privileged` + `full_access: true`:

| Host Path | Container Path | Mode | Purpose | Required |
|-----------|---------------|------|---------|----------|
| `/sys/fs/bpf` | `/sys/fs/bpf` | rw,shared | BPF maps & programs | **YES** |
| `/var/run/cilium` | `/var/run/cilium` | rw | Runtime state, sockets | **YES** |
| `/var/run/netns` | `/var/run/cilium/netns` | rw | Network namespaces | **YES** |
| `/run/cilium/cgroupv2` | `/run/cilium/cgroupv2` | rw | cgroup v2 | **YES** |
| `/lib/modules` | `/lib/modules` | ro | Kernel modules | **YES** |
| `/run/xtables.lock` | `/run/xtables.lock` | rw | iptables lock | **YES** |
| `/proc/sys/net` | `/host/proc/sys/net` | rw | Sysctl tuning | **YES** |
| `/proc/sys/kernel` | `/host/proc/sys/kernel` | rw | Kernel params | **YES** |
| `/opt/cni/bin` | — | — | CNI binaries | **SKIP** |
| `/etc/cni/net.d` | — | — | CNI config | **SKIP** |

With `full_access: true` and `privileged` in the HA addon config, all host paths are accessible. The Docker container runs with `--privileged --network=host --pid=host` which gives us everything.

## RBAC

For a prototype, use the existing `cilium` ServiceAccount kubeconfig (or cluster-admin). The exact RBAC from the Helm chart's `cilium` ClusterRole includes:

- **Core**: get/list/watch on `nodes`, `services`, `endpoints`, `namespaces`, `pods`, `secrets`, `configmaps`
- **Cilium CRDs**: full CRUD on `ciliumnodes`, `ciliumendpoints`, `ciliumidentities`, plus list/watch on all other Cilium CRDs
- **Networking**: get/list/watch on `networkpolicies`, `endpointslices`
- **Node management**: get/create/update/patch on `nodes`, `nodes/status`
- **Leases**: get/create/update/patch on `coordination.k8s.io/leases`
- **CRD definitions**: get/list/watch on `apiextensions.k8s.io/customresourcedefinitions`

## Risks & Mitigations

| Risk | Severity | Mitigation |
|------|----------|------------|
| **CiliumNode GC'd** (no OwnerRef Node) | CRITICAL | We create a real Node object BEFORE agent starts. Agent sets OwnerRef with the Node's UID. Heartbeat keeps Node alive. |
| **Agent crashes without kubelet** | MEDIUM | The agent's own health check (`/healthz`) is internal HTTP, not kubelet-dependent. CNI install disabled. `WaitForNodeInformation` times out after 10s gracefully. |
| **HAOS kernel lacks BTF** | MEDIUM | Cilium has legacy BPF probe fallback. Init script checks and warns. |
| **WireGuard module missing** | LOW | HAOS 13+ has kernel 6.1+ with WireGuard built-in. Init script verifies. |
| **DaemonSet tries to schedule on our node** | LOW | NoSchedule + NoExecute taints. Cilium DaemonSet tolerates all, but since we already run the agent ourselves, a duplicate pod would just fail to bind ports. |

## Acceptance Criteria

- [ ] Addon installs via custom repository URL on HAOS
- [ ] cilium-agent connects to k3s API and creates CiliumNode
- [ ] CiliumNode has correct OwnerReference to Node object
- [ ] WireGuard interface `cilium_wg0` created with cluster node peers
- [ ] VXLAN interface `cilium_vxlan` created
- [ ] `ping <pod-ip>` from HA machine reaches a pod in cluster
- [ ] `cilium-dbg encrypt status` shows WireGuard peers
- [ ] Addon survives restart cleanly
- [ ] Node stays "Ready" via heartbeat

## Testing Plan

1. Build Docker image: `docker buildx build --platform linux/arm64 -t cilium-router:dev .`
2. Push to GHCR or load onto HA directly
3. Place kubeconfig at `/share/cilium/kubeconfig`
4. Start addon, tail logs
5. Verify: `kubectl get nodes` — see `ha-cilium` as Ready
6. Verify: `kubectl get ciliumnodes ha-cilium -o yaml` — has WireGuard pubkey annotation
7. Verify: from HA, `ping <pod-ip>` works
8. Verify: from pod, `ping <ha-machine-ip>` works
9. Verify: `kubectl exec -n kube-system ds/cilium -- cilium-dbg encrypt status` shows HA as peer

## Note on Cilium DaemonSet Conflict

The cluster's Cilium DaemonSet tolerates all taints (`operator: Exists`). It WILL try to schedule a cilium pod on our node. Since we already run cilium-agent in the addon, the DaemonSet pod will conflict (port 9879 etc). Solutions:
- Add a nodeSelector to the Cilium Helm values excluding our node (cleanest)
- Or let it fail — the pod will be in CrashLoopBackOff but our addon agent works fine
- Or add an anti-affinity label: `helm upgrade cilium --set affinity.nodeAntiAffinity...`
