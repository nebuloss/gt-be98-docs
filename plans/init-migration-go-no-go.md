# Init migration (rc → systemd/other PID1) — go/no-go verdict

Date: 2026-06-06. Investigated per the Buildroot-takeover roadmap (M5.3),
**before any code**. Verdict applies to the current trial-flash scope (reuse
of the proven 0031 bootfs/kernel; kernel rebuild deferred per Step 2b).

## Verdict: **NO-GO** for any PID1 replacement; modernize beside `rc` (stage i)

### Blocking evidence

1. **Kernel lacks cgroups entirely** — live `zcat /proc/config.gz` on the
   running 4.19.294 vendor kernel (br-0032, 2026-06-06):
   `# CONFIG_CGROUPS is not set`. systemd hard-requires cgroups (any
   hierarchy). Also `# CONFIG_FHANDLE is not set` (udevd needs
   name_to_handle_at). Both would require a **kernel rebuild** — explicitly
   deferred (Step 2b verdict: vendoring the Broadcom kernel build wrapper is
   multi-day for no functional gain, and a changed kernel reopens the
   crash-loop gap the flash harness cannot cover).
   (Present and fine: EPOLL, SIGNALFD, TIMERFD, INOTIFY_USER, DEVTMPFS+MOUNT,
   AUTOFS4; missing TMPFS_POSIX_ACL would degrade logind/tmpfiles ACLs.)

2. **`rc` is not just an init** — hardware-coupled duties that any PID1
   replacement must reproduce (mapped from source + live behavior):
   - `bcm_boot_launcher start` rail (init.c:25000): S25mount-fs writes the
     **`steadystate` boot marker** (`/proc/bootstate/reset_reason`) which
     reports boot success to the SMC (resets SMC boot watchdog/fail count,
     `bcm_rpc_ba_report_boot_success`). Missing this = the SMC counts every
     boot as failed.
   - HW watchdog feeding (`watchdog` daemon, KEEP verdict).
   - wlconf/dhd radio bring-up, nvram daemons, `sync_boot_state` slot
     management (init.c:27102), SDN/apg VLAN plumbing via `restart_wireless`.
   - busybox `init`/`sh` are ASUS-built; no inittab-style hooks for foreign
     unit supervision.

3. **Toolchain ceiling**: gcc 10.3 / glibc 2.32. Recent systemd needs newer
   toolchain features (≥ v250 wants gcc ≥ 11-era C11 atomics/compiler
   support and meson versions beyond what the external toolchain ships);
   an old-enough systemd (v24x) would still hit blocker #1.

### What IS viable (adopted path)

- **Stage (i) only**: new Buildroot-built services run *beside* rc, installed
  under a separate prefix (`/opt/br`) or as static binaries; ASUS rc remains
  PID1 and owns hardware bring-up. Start hooks: the proven boot-rail
  (S-scripts, e.g. S26trial-deadman) or /jffs services-start.
- Supervision gap (no systemd Restart=): use the existing pattern — ASUS
  watchdog `_check` respawners for ASUS daemons; for our additions, a small
  rail-started babysitter loop if needed (the dead-man already demonstrates
  the pattern).
- Re-evaluate only if Step 2b (kernel from source) is ever reopened — then
  enable CGROUPS/FHANDLE first and revisit stage (ii) (shim PID1) with the
  same trial-flash discipline.
