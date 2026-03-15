# Cilium Router for Home Assistant

A Home Assistant addon that runs Cilium agent to make your Home Assistant machine part of a Kubernetes cluster's network. Pods and ClusterIP services become directly reachable from your HA machine. This Home Assistant app exist because the now-removed feature of cilium "External Workloads" is gone.

## How it works

The addon runs the real `cilium-agent` binary (from the official Cilium 1.19 image) inside a privileged Docker container. It connects to your k3s cluster's API server via a kubeconfig you provide, creates a lightweight tainted Node object (nothing gets scheduled on it), and lets cilium-agent handle the rest: CiliumNode registration, WireGuard tunnel setup, VXLAN overlay, and BPF program installation.

## Getting started

### 1. Add the repository

In Home Assistant, go to **Settings > Add-ons > Add-on Store > ⋮ > Repositories** and add:

```
https://github.com/eliottness/cilium-homeassistant
```

### 2. Install the addon

Find **Cilium Router** in the store and click **Install**. Then toggle off the **Protection Mode** button.

### 3. Configure

Place your kubeconfig file at `/config/kubeconfig` (editable via the **File Editor** or **SSH** addon). The kubeconfig needs at least the `cilium` ClusterRole permissions (or `cluster-admin` for prototyping).

### 4. Exclude the HA node from Cilium DaemonSet

The cluster's Cilium DaemonSet will try to schedule a pod on the `ha-cilium` node. Since the addon already runs cilium-agent, this pod is unnecessary and will fail (no CPU/memory reported by the fake node). Add this to your Cilium Helm values to exclude it:

```yaml
affinity:
  nodeAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      nodeSelectorTerms:
        - matchExpressions:
            - key: node-role.kubernetes.io/cilium-router
              operator: DoesNotExist

# Enable ClusterIP access from the HA machine via TC/XDP datapath
bpf:
  lbExternalClusterIP: true
```

Then upgrade Cilium:

```bash
helm upgrade cilium cilium/cilium -n kube-system -f values.yaml
```

### 5. DNS (optional)

HA runs its own CoreDNS at `172.30.32.3` which doesn't know about `cluster.local` domains. To resolve Kubernetes service names from HA, add your CoreDNS ClusterIP as a DNS server:

**Option A**: Go to **Settings > System > Network > DNS** and add your CoreDNS ClusterIP (e.g., `10.85.0.10`) alongside your existing DNS server.

**Option B**: Add a forward zone to the hassio_dns Corefile at `/usr/share/hassio/dns/coredns.tmpl` (via SSH addon):

```
cluster.local {
    forward . 10.85.0.10
    log
}
```

Then restart DNS: `ha dns restart`

### 6. Start

Click **Start** and check the **Log** tab. You should see:
- Cluster connectivity OK
- Node created
- Cilium config fetched (160+ keys)
- Agent starting

### 6. Verify

```bash
# Check the node appeared:
kubectl get nodes ha-cilium

# Check CiliumNode has WireGuard key:
kubectl get ciliumnodes ha-cilium -o yaml | grep -A5 wireguard

# Check ha-cilium appears in the node list:
kubectl exec -n kube-system ds/cilium -- cilium-dbg node list

# Check WireGuard peers include ha-cilium:
kubectl exec -n kube-system ds/cilium -- cilium-dbg encrypt status

# Test connectivity from HA to a pod:
ping <any-pod-ip>
```

## Requirements

- Home Assistant OS 13+ (kernel 6.1+ with eBPF and WireGuard support)
- A cluster with Cilium 1.19+ (tested in tunnel mode, WireGuard encryption)
- A kubeconfig with sufficient RBAC permissions

## Configuration

| Option | Default | Description |
|--------|---------|-------------|
| `kubeconfig_path` | `/config/kubeconfig` | Path to the kubeconfig file inside the addon |
| `node_name` | `ha-cilium` | Name for the K8s Node object created in the cluster |
| `log_level` | `info` | Cilium agent log level (`info`, `debug`, `warning`, `error`) |

## Architecture

```
HA Machine                          K8s Cluster
┌──────────────────┐               ┌──────────────────┐
│ cilium-agent     │◄──   VXLAN ──►│ cilium-agent     │
│  ├ cilium_wg0    │               │  ├ cilium_wg0    │
│  ├ cilium_vxlan  │               │  ├ cilium_vxlan  │
│  └ BPF programs  │               │  └ BPF programs  │
│                  │               │                  │
│ kubeconfig ──────┼──── K8s API ──┤ kube-apiserver   │
└──────────────────┘               └──────────────────┘
```

## Known limitations

- **Prototype** — cilium-agent has never been officially tested without a kubelet. It works for routing but edge cases may exist.
- **ClusterIP services require `bpf.lbExternalClusterIP: true`** in your Cilium Helm values. Without it, only pod IPs are reachable. See step 4 above.
- **No BTF on HAOS** — the Home Assistant OS kernel doesn't ship with `CONFIG_DEBUG_INFO_BTF`. Cilium falls back to legacy BPF probe mode which works but is slower to start.
- **No pod scheduling** — the HA node is tainted `NoSchedule` + `NoExecute`. It only participates in routing.
