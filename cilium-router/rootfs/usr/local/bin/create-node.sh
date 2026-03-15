#!/bin/bash
set -euo pipefail

export KUBECONFIG=/etc/cilium/kubeconfig
NODE_NAME="${NODE_NAME:-ha-cilium}"
NODE_IP=$(ip route get 1.1.1.1 | awk '{print $7; exit}')
ARCH=$(uname -m)
[ "$ARCH" = "aarch64" ] && ARCH="arm64"
[ "$ARCH" = "x86_64" ] && ARCH="amd64"

if kubectl get node "${NODE_NAME}" > /dev/null 2>&1; then
    echo "[node] Node '${NODE_NAME}' already exists"
else
    echo "[node] Creating Node '${NODE_NAME}' at ${NODE_IP}..."
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

echo "[node] Node '${NODE_NAME}' ready at ${NODE_IP}"
