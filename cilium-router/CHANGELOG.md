# Changelog

## 0.1.1

- Match DaemonSet pod behavior: bind-mount host paths (`/var/run/cilium`, netns, xtables.lock, `/lib/modules`, `/sys/fs/bpf`) instead of container-local directories
- Add missing capabilities to match DaemonSet security context: `CHOWN`, `KILL`, `IPC_LOCK`, `SYS_PTRACE`, `SYS_CHROOT`, `DAC_OVERRIDE`, `FOWNER`, `SETGID`, `SETUID`, `SYSLOG`
- Fetch clustermesh secrets from cluster (cilium-clustermesh, remote-cert, local-cert)
- Export missing env vars: `CILIUM_CLUSTERMESH_CONFIG`, `KUBE_CLIENT_BACKOFF_BASE`, `KUBE_CLIENT_BACKOFF_DURATION`
- Remove extra `--bpf-root`, `--state-dir`, `--lib-dir` flags from agent invocation to match DaemonSet exactly

## 0.1.0

- Initial release
- Runs `cilium-agent` v1.19.0 from official Cilium image
- Multi-arch support: `aarch64` and `amd64`
- Automatic K8s Node object creation with NoSchedule/NoExecute taints
- BPF filesystem and cgroup v2 mount handling
- Fetches real `cilium-config` ConfigMap via `cilium-dbg build-config`
- Node heartbeat service keeps Node in `Ready` state via lease renewal
- WireGuard + VXLAN tunnel support for cluster pod routing
