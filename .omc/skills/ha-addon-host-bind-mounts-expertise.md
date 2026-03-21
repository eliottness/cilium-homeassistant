# Home Assistant Addon: Host Bind Mounts via Docker Overlay

## The Insight

HA addons can't specify arbitrary bind mounts. To access host paths from inside an addon container, you must:
1. Find your container ID from `/proc/self/mountinfo` (parse the resolv.conf mount)
2. Get the overlay merged dir via `nsenter --target 1 --mount -- docker inspect`
3. Use `nsenter --target 1 --mount -- mount --bind /host/path ${MERGED_DIR}/container/path`
4. Restart the container — mounts become visible on the second start

This pattern comes from [netdata-hass-addon](https://github.com/felipecrs/netdata-hass-addon).

## Why This Matters

Without this, you CANNOT access host filesystems like `/sys/fs/bpf`, `/var/run/cilium`, `/lib/modules` from an HA addon. The naive approach (`mount --bind /proc/1/root/...`) fails because the kernel blocks bind mounts across namespace boundaries via `/proc`.

## Recognition Pattern

- "mount: wrong fs type, bad superblock on /proc/1/root/..." errors
- "Permission denied" when trying to `mkdir -p /proc/1/root/...`
- Need to share host kernel state (BPF maps, network namespaces, modules) with a container

## The Approach

1. **Never use `/proc/1/root/` as a bind mount source** — it doesn't work
2. **Use `/proc/1/root/` only for reading/writing files** (cp, rm) — this works with `DAC_READ_SEARCH` or `SYS_PTRACE`
3. **For bind mounts, use the merged dir pattern**: nsenter into host, mount host path into container's overlay merged dir
4. **Mount points must exist in the image** — create them in Dockerfile, or mkdir in the merged dir before mounting
5. **Container restart is required** — mounts done from host side aren't visible inside until restart
6. **Use `mountpoint -q` check** to detect if mounts are already present (skip on second start)

## Gotchas

- `/sys/fs/bpf`: Docker already mounts its own bpffs inside the container. Bind-mounting the host's on top causes `"multiple mount points detected"` fatal error in cilium-agent. Mount to a different path (e.g., `/host/bpf`) and use `--bpf-root=/host/bpf`.
- `/run/cilium/cgroupv2`: Bind-mounting the host's cgroupv2 over the container's BREAKS cgroup BPF program attachment that was working with the container-local cgroupv2. Don't bind-mount this.
- Mount point directories in the overlay merged dir may not exist if they come from runtime mounts (tmpfs, sysfs) rather than image layers. Create them with `mkdir -p` in the merged dir before binding.
- `nsenter` for mkdir on host works: `nsenter --target 1 --mount -- mkdir -p /var/run/cilium`
