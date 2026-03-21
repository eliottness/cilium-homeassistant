# Cilium Agent on Home Assistant: Key Differences from DaemonSet

## The Insight

Running cilium-agent as an HA addon instead of a DaemonSet pod requires several non-obvious overrides because there's no kubelet, no kube-proxy, and the host filesystem is read-only squashfs. The cluster's ConfigMap settings are tuned for real k8s nodes and break on the HA node.

## Why This Matters

Without these overrides, the agent either crashes, can't route traffic, or can't translate service IPs. Each failure mode looks different and requires separate debugging.

## Recognition Pattern

- cilium-agent crashes with "unable to determine direct routing device"
- Service IPs hang at `connect()` — no DNAT happening
- `bpftool cgroup tree` shows no `connect4`/`connect6` programs
- `tc filter show dev <iface> egress` is empty
- Node IP shows as `0` in kubectl

## Critical Config Overrides (beyond what cilium-config provides)

```bash
# Socket-level LB: MANDATORY when no kube-proxy
# The cluster ConfigMap has bpf-lb-sock=false because real nodes use kube-proxy.
# Without this, connect() to Service IPs goes nowhere.
printf '%s' "true" > /tmp/cilium/config-map/bpf-lb-sock

# These are intentional for no-kubelet operation:
printf '%s' "false" > /tmp/cilium/config-map/enable-l7-proxy
printf '%s' ""      > /tmp/cilium/config-map/write-cni-conf-when-ready
printf '%s' "false" > /tmp/cilium/config-map/enable-health-check-nodeport
printf '%s' "false" > /tmp/cilium/config-map/cni-exclusive
printf '%s' "/etc/cilium/kubeconfig" > /tmp/cilium/config-map/k8s-kubeconfig-path
printf '%s' "/proc" > /tmp/cilium/config-map/procfs
```

## CLI flags needed

- `--bpf-root=/host/bpf` — because Docker's `/sys/fs/bpf` conflicts with host bind mount
- `--direct-routing-device=<auto-detected>` — agent can't auto-detect on HA, derive from `ip route get <api-server>`

## Debugging Service IP Issues

1. `cilium-dbg service list` — are services synced? (usually yes)
2. `cilium-dbg bpf lb list` — are LB map entries populated? (usually yes)
3. `bpftool cgroup tree /run/cilium/cgroupv2/` — are connect4/connect6 attached? **THIS is usually the problem**
4. `tc filter show dev end0 egress` — TC programs? (empty with legacy host routing, that's expected)
5. If connect programs missing → check `bpf-lb-sock` config value

## HA Supervisor Capability Allowlist

Only these capabilities can be requested in `config.yaml`:
```
BPF, CHECKPOINT_RESTORE, DAC_READ_SEARCH, IPC_LOCK, NET_ADMIN, NET_RAW,
PERFMON, SYS_ADMIN, SYS_MODULE, SYS_NICE, SYS_PTRACE, SYS_RAWIO,
SYS_RESOURCE, SYS_TIME
```

Capabilities like CHOWN, KILL, DAC_OVERRIDE, FOWNER, SETGID, SETUID, SYSLOG, SYS_CHROOT are NOT in the allowlist. The supervisor rejects the entire addon config if you include them.

## HAOS Filesystem Layout

- `/dev/root` (squashfs) — READ-ONLY, 100% used
- `/var` (tmpfs) — writable, ephemeral (lost on reboot)
- `/run` (tmpfs) — writable, ephemeral
- `/mnt/data` (mmcblk0p8) — writable, persistent (Docker lives here)
- `/sys` — virtual, writable

Host paths `/var/run/cilium`, `/run/xtables.lock` are on tmpfs → writable.
Host paths `/lib/modules`, `/etc/cni` are on squashfs → read-only.

## Node IP Detection

`ip route get` output format varies across systems. Don't use hardcoded awk field positions:
```bash
# BAD — field position varies
ip route get 1.1.1.1 | awk '{print $7; exit}'

# GOOD — parse the 'src' keyword
ip route get 1.1.1.1 | sed -n 's/.*src \([^ ]*\).*/\1/p'
```
