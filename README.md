# Cilium Router for Home Assistant

A Home Assistant addon that runs Cilium agent to make your Home Assistant machine part of a Kubernetes cluster's network. Pods become directly reachable from your HA machine via Cilium's WireGuard + VXLAN tunnels.

## How it works

The addon runs the real `cilium-agent` binary (from the official Cilium 1.19 image) inside a privileged Docker container. It connects to your k3s cluster's API server via a kubeconfig you provide, creates a lightweight tainted Node object (nothing gets scheduled on it), and lets cilium-agent handle the rest: CiliumNode registration, WireGuard tunnel setup, VXLAN overlay, and BPF program installation.

## Getting started

### 1. Add the repository

In Home Assistant, go to **Settings > Add-ons > Add-on Store > ⋮ > Repositories** and add:

```
https://github.com/eliottness/cilium-homeassistant
```

### 2. Install the addon

Find **Cilium Router** in the store and click **Install**.

### 3. Configure

Go to the **Configuration** tab and paste your kubeconfig content into the `kubeconfig` field. The kubeconfig needs at least the `cilium` ClusterRole permissions (or `cluster-admin` for prototyping).

### 4. Start

Click **Start** and check the **Log** tab. You should see:
- Cluster connectivity OK
- BPF filesystem mounted
- Node created
- Cilium config fetched
- Agent starting

### 5. Verify

```bash
# Check the node appeared:
kubectl get nodes ha-cilium

# Check CiliumNode with WireGuard key:
kubectl get ciliumnodes ha-cilium

# Test connectivity:
ping <any-pod-ip>
```

## Requirements

- Home Assistant OS 13+ (kernel 6.1+ with eBPF and WireGuard support)
- k3s cluster with Cilium 1.19+ (tunnel mode, WireGuard encryption)
- A kubeconfig with sufficient RBAC permissions

## Architecture

```
HA Machine                          K8s Cluster
┌──────────────────┐               ┌──────────────────┐
│ cilium-agent     │◄──WireGuard──►│ cilium-agent     │
│  ├ cilium_wg0    │   (UDP 51871) │  ├ cilium_wg0    │
│  ├ cilium_vxlan  │               │  ├ cilium_vxlan  │
│  └ BPF programs  │               │  └ BPF programs  │
│                  │               │                  │
│ kubeconfig ──────┼──── K8s API ──┤ kube-apiserver   │
└──────────────────┘               └──────────────────┘
```

## Known limitations

- **Prototype** — cilium-agent has never been officially tested without a kubelet. It works for routing but edge cases may exist.
- **DaemonSet conflict** — the cluster's Cilium DaemonSet will try to schedule on the HA node. Either add a nodeSelector to exclude it or let it crashloop (harmless).
- **No pod scheduling** — the HA node is tainted `NoSchedule` + `NoExecute`. It only participates in routing.
