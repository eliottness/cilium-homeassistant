# Changelog

## 0.1.0

- Initial release
- Runs `cilium-agent` v1.19.0 from official Cilium image
- Multi-arch support: `aarch64` and `amd64`
- Automatic K8s Node object creation with NoSchedule/NoExecute taints
- BPF filesystem and cgroup v2 mount handling
- Fetches real `cilium-config` ConfigMap via `cilium-dbg build-config`
- Node heartbeat service keeps Node in `Ready` state via lease renewal
- WireGuard + VXLAN tunnel support for cluster pod routing
