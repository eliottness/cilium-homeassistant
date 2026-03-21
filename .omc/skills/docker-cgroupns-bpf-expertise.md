# Docker cgroup namespace isolation breaks BPF cgroup program attachment

## The Insight

When a process inside a Docker container (cgroupns=private, the default since Docker 20.10) opens a cgroup2 mount point — whether bind-mounted from the host or freshly mounted — the kernel returns an fd scoped to the **container's cgroup**, not the host's root cgroup. BPF programs attached via `bpf_link_create()` to this fd only fire for processes within that container's cgroup subtree, not for all host processes.

This is a **namespace illusion**: the mount looks correct, logs say "cgroup2 detected", BPF link creation succeeds with no errors, but the programs are attached to the wrong inode.

## Why This Matters

Without this knowledge, you can spend hours debugging why BPF socket-level load balancing "attaches successfully" but doesn't intercept traffic from host processes. Every diagnostic looks green:
- Cilium logs confirm cgroup2 mount detected
- BPF link creation succeeds for all programs
- Pin files exist at the expected paths

The only clue is `bpftool cgroup show /path` returning empty — but that's actually expected when using `bpf_link` (vs legacy `BPF_PROG_ATTACH`), so it's a red herring.

## Recognition Pattern

- Cilium (or any BPF cgroup program) running inside a Docker container
- Socket LB or cgroup BPF programs "attach successfully" but have no effect on host traffic
- `bpftool link list` shows the programs attached, but they don't fire for host processes
- Container uses `host_pid: true` but NOT `cgroupns: host`
- Bind-mounting `/sys/fs/cgroup` into the container doesn't help

## The Approach

**Mental model**: Think of cgroup namespaces like mount namespaces for cgroups. Opening any cgroup2 path inside a private cgroup namespace always resolves to the container's cgroup root, regardless of bind mounts. The inode you get is the container's cgroup, not what you see on the host.

**Decision heuristic**: If a process needs to attach BPF programs to the host's root cgroup but runs in a container with private cgroup namespace:
1. **Preferred**: Use `nsenter --cgroup=/proc/1/ns/cgroup` to enter the host's cgroup namespace before the target process starts (requires `host_pid: true` for `/proc/1/ns/cgroup` access)
2. **Alternative**: Run the container with `--cgroupns=host` (if the container runtime exposes this option)
3. **Verify**: `bpftool link list | grep cgroup` to confirm programs are linked, then test actual traffic interception

## Example

```bash
# BROKEN: cilium-agent opens /host/cgroup inside private cgroupns
# → fd points to container's cgroup inode, not host root
cilium-agent --cgroup-root=/host/cgroup

# FIXED: enter host cgroup namespace first
# → fd points to real host root cgroup inode
nsenter --cgroup=/proc/1/ns/cgroup -- \
    cilium-agent --cgroup-root=/host/cgroup
```

## Triggers

- "bpf cgroup attach no effect"
- "socket LB not working docker"
- "cilium cgroup namespace"
- "bpf_link_create wrong cgroup"
- "cgroupns private bpf"
- "connect() not intercepted host"
