# Devcontainer performance

If the devcontainer feels slow (sluggish builds, OOM-killed processes, laggy
editors), the fix is almost never in this repo — it's in how much CPU/RAM the
host actually grants the container. This guide covers the one knob that lives
here and the real provisioning levers that live elsewhere.

## The `hostRequirements` floor

`.devcontainer/devcontainer.json` (and the `dev/` profile) declares the **minimum**
the container needs to run its intended workload (Playwright + agents):

```jsonc
"hostRequirements": {
  "cpus": 2,
  "memory": "4gb"
}
```

This is a **floor, not a target**. **Codespaces** enforces it — it won't offer a
machine below these specs, so don't inflate it (that only forces a bigger, costlier
machine than you need). **VS Code** warns when the host is under it. **Coder**
ignores it. Raising these numbers does **not** give the container more resources;
it only gates startup. For actual headroom, use the two levers below.

## Coder workspace quota (lives in harmon-infra)

When the devcontainer runs in a Coder workspace, its CPU/RAM ceiling is the
**workspace's** quota, set by the Coder template — which is org-level
infrastructure (the canonical example is `terraform/coder/devcontainer/` in
[harmonops/harmon-infra](https://github.com/harmonops/harmon-infra)), **not**
this repo. To give the container more headroom, raise the CPU/memory parameters
(or the resource limits) on the Coder template / workspace there, then rebuild
the workspace.

## WSL2 memory (lives in `.wslconfig`)

On Windows, Docker Engine runs inside a WSL2 distro, so the container can never
exceed what WSL2 itself is allowed. That cap is the WSL2 VM's, set per-user in
`%UserProfile%\.wslconfig` (create it if absent):

```ini
[wsl2]
memory=12GB     # hard limit on RAM the WSL2 VM may use
processors=6    # number of logical CPUs
swap=4GB        # swap file size (0 disables swap)
```

Changes take effect only after a full restart of the WSL2 VM:

```powershell
wsl --shutdown
```

Then reopen the container. Without `wsl --shutdown`, the old limits stay in
effect even after editing the file.

## Triage: is it the container or the host?

Before tuning, find out which side is starved:

- **Inside the container**, check what the container *sees*:
  `nproc` (CPUs) and `free -h` (memory). If these are already low, the host is
  capping you — raise the Coder quota or `.wslconfig` above.
- **On the host**, watch real usage during the slow operation (Activity Monitor
  / Task Manager, or `docker stats`). If the host is maxed out while the
  container's limits look generous, the bottleneck is the host machine itself —
  close other workloads or move to a bigger machine.

Rule of thumb: a slow **build** is usually CPU/IO; an **OOM-killed** or thrashing
process is memory — bump `memory` (and `swap` on WSL2) accordingly.

## See also

- [devcontainers.md](devcontainers.md) — the dual-profile devcontainer overall.
- [troubleshooting.md](troubleshooting.md) — other devcontainer issues.
