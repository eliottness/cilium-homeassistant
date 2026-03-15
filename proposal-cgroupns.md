# Feature request: add `cgroup_namespace` option to addon configuration

## Problem

On cgroup v2 hosts, Docker defaults to `--cgroupns=private` for containers. The Supervisor doesn't override this, so addon containers get their own cgroup namespace. This is fine for most addons, but it breaks one specific thing: BPF programs attached to cgroup hooks only affect processes inside the addon container, not host processes or other containers.

This matters for addons that need to do system-level monitoring or networking. For example, any addon that attaches eBPF programs to cgroup hooks for traffic accounting, resource monitoring, or network interception will only see its own container's traffic — not the host's or other addons'. There have been [community discussions](https://community.home-assistant.io/t/s6-overlay-suexec-fatal-can-only-run-as-pid-1/426969) about addons needing deeper system access, and the cgroup namespace is one of the remaining gaps.

The kernel blocks `setns()` from a child cgroup namespace to a parent — by design, not a bug. So there's no workaround from inside a running container. The container has to be started with `--cgroupns=host`.

In Kubernetes, privileged pods get `--cgroupns=host` automatically via the container runtime. Docker doesn't do this, even with `--privileged`.

## Proposed solution

Add a `cgroup_namespace` option to addon config, mapping to Docker's `cgroupns_mode` parameter:

```yaml
# addon config.yaml
cgroup_namespace: host
```

The Supervisor already exposes the other namespace options:

| Option | Docker flag |
|---|---|
| `host_network` | `--network=host` |
| `host_pid` | `--pid=host` |
| `host_ipc` | `--ipc=host` |
| `host_uts` | `--uts=host` |
| `cgroup_namespace` | `--cgroupns=host` (proposed) |

### Values

| Value | Behavior |
|---|---|
| *(not set)* | Docker daemon default (`private` on cgroup v2, `host` on cgroup v1) |
| `host` | Container shares the host's cgroup namespace |
| `private` | Container gets its own cgroup namespace (current default) |

The Docker Python SDK already supports `cgroupns_mode` (API 1.41 / Docker CE 20.10).

## Security

`cgroup_namespace: host` exposes the host's cgroup hierarchy inside the container. It's roughly the same level of access as `host_pid: true` (which exposes all host processes) — both are declared in `config.yaml` and visible to users at install time. Any addon requesting this would already need `SYS_ADMIN` and `NET_ADMIN` anyway.

## Why I need this

I'm building an addon that uses eBPF for network-level features. The BPF programs compile, load, and attach correctly inside the container. But because the container has a private cgroup namespace, the programs only intercept syscalls from processes inside the addon itself — not from other addons or the host.

I tried every workaround I could think of:
- `nsenter --cgroup=/proc/1/ns/cgroup` — Permission denied (kernel blocks child-to-parent setns)
- `mount --bind /proc/1/root/sys/fs/cgroup` — fails
- Pointing the BPF cgroup root at `/proc/1/root/sys/fs/cgroup` — attach still resolves to the container's cgroup

None of them work because the kernel enforces cgroup namespace isolation at the syscall level. The only fix is `--cgroupns=host` at container start time.

## References

- [HA Community: Ability to allow addons to mount system volumes](https://community.home-assistant.io/t/ability-to-allow-addons-to-mount-system-volumes/860365/2) — same need from a Datadog Agent addon
- [Docker CLI --cgroupns PR](https://github.com/docker/cli/pull/2024)
- [Kubernetes hostCgroup feature request](https://github.com/kubernetes/kubernetes/issues/103363) — same gap in K8s
- [Cilium #15137](https://github.com/cilium/cilium/issues/15137) — BPF attached to wrong cgroup due to namespace isolation
- [Compose spec #148](https://github.com/compose-spec/compose-spec/issues/148) — Docker Compose also lacks this
