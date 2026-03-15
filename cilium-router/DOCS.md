# Cilium Router Addon

Runs `cilium-agent` on Home Assistant so the machine participates in the Cilium network as a routing node. Pods in the cluster become directly reachable via Cilium's WireGuard + VXLAN tunnels.

## Prerequisites

- k3s cluster with Cilium 1.19+
- A kubeconfig with sufficient RBAC (cilium ClusterRole or cluster-admin for prototyping)
- HAOS 13+ (kernel 6.1+ with WireGuard and eBPF support)

## Setup

1. Install this addon from the custom repository.
2. Go to the **Configuration** tab.
3. Paste your kubeconfig content into the `kubeconfig` field.
4. Adjust `node_name` if desired (default: `ha-cilium`).
5. Start the addon.

## Configuration

| Option | Default | Description |
|--------|---------|-------------|
| `kubeconfig` | *(empty)* | Paste the full contents of your kubeconfig file here |
| `node_name` | `ha-cilium` | Name for the K8s Node object created in the cluster |
| `log_level` | `info` | Cilium agent log level (`info`, `debug`, `warning`, `error`) |

## What it does

1. Writes the kubeconfig and tests cluster connectivity.
2. Mounts BPF filesystem and cgroup v2.
3. Sets required sysctls (ip_forward, bpf_jit, rp_filter).
4. Creates a tainted K8s `Node` object (NoSchedule + NoExecute — nothing gets scheduled on it).
5. Fetches the `cilium-config` ConfigMap from the cluster (same config as in-cluster agents).
6. Starts `cilium-agent` — creates CiliumNode CRD, sets up WireGuard and VXLAN interfaces, installs BPF programs.
7. Runs a heartbeat loop to keep the Node in `Ready` state.

## Verification

```bash
# Check the node appeared in the cluster:
kubectl get nodes ha-cilium

# Check CiliumNode has WireGuard public key:
kubectl get ciliumnodes ha-cilium -o yaml

# Test pod connectivity from HA machine:
ping <pod-ip>

# Verify WireGuard peering from a cluster node:
kubectl exec -n kube-system ds/cilium -- cilium-dbg encrypt status
```

## DaemonSet Conflict

The cluster's Cilium DaemonSet tolerates all taints and will try to schedule a cilium pod on the `ha-cilium` node. Since we already run cilium-agent in this addon, the DaemonSet pod will conflict. Options:

- **Recommended**: Add a nodeSelector to exclude this node in your Cilium Helm values:
  ```yaml
  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
          - matchExpressions:
              - key: node-role.kubernetes.io/cilium-router
                operator: DoesNotExist
  ```
- **Alternative**: Let the DaemonSet pod crashloop — it won't affect the addon's agent.
