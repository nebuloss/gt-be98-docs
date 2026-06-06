# GT-BE98 Buildroot takeover — session N+1 prompt (M4 slices → M5)

You are an autonomous agent with **no human in the loop**. Never ask
questions; decide from this prompt + the referenced docs + live evidence,
pick the conservative option when unsure, and log every decision in
`gt-be98-docs/flash-journal.md`. You may flash, reboot, and modify the
firmware under the safety invariants in §3 — they override everything.

## 0. Mission for this session

1. **M4 — strip stock ASUS services in ≤5-removal slices**, one trial cycle
   per slice, on the br-0034 baseline. Along the way, **bisect which of the
   br-0033 batch-1 removals broke network bring-up** (see §5).
2. When M4 slices are done (or parked after 3 failed attempts on the same
   slice): start **M5 — modernization beside rc** (`/opt/br` prefix,
   init migration is a documented NO-GO, do not reopen).

"Done" = booted on the device, validation gate passed, committed, journal
+ AGENTS.md updated, backups refreshed, all repos committed.

## 1. Environment (verified 2026-06-06)

- Workspace `~/be98/`: `gt-be98-buildroot/` (THE repo — read its
  `AGENTS.md` first), `buildroot-m1/` (build dir, `BR2_DL_DIR=~/be98/buildroot/dl`
  pre-seeded), `gt-be98-firmware/` (merlin reference), `gt-be98-docs/`
  (knowledge base — READ `flash-journal.md` 2026-06-05/06 entries and
  `recovery-procedure.md` CORRECTIONS section before touching the device),
  `gt-be98-packages/`, `~/be98/artifacts-br/` (br-0032 `6c3b8918…`,
  br-0033 `8f0b70a1…` QUARANTINED — never flash, br-0034 `d1b40b0f…`),
  `~/be98/device-backups/`.
- Build: `cd ~/be98/buildroot-m1 && export BR2_DL_DIR=~/be98/buildroot/dl
  && make` → `output/images/GT-BE98_nand_squashfs.pkgtb`. Bump
  `board/gt-be98/RELEASE` (br-00NN, monotonic) and COMMIT before the final
  build so the identity marker carries a clean git SHA.
- Git identity in every repo: `guillaume <guillaume.chaye@zeetim.com>`;
  commit trailer `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.
- Device: ASUS GT-BE98, production AP (sw_mode=3), 3 user nets
  (Ramondia/br20, Pagoa/br30, DEV-SCEP/br50). **SSH
  `admin@10.0.0.8 -p 2222`** (key auth). On-device: run scripts as
  `/bin/sh script`; `/sbin/sh` is NOT a shell.
- **This host probes the AP ROUTED (host is on VLAN 50 / 10.0.50.x).** If
  the AP vanishes: it may be up with a changed lease — `nmap -p 2222 --open
  10.0.0.0/24` (nmap installed for this), and remember address-specific
  inter-VLAN firewall rules can hide a healthy AP. Harness scripts take
  `GT_BE98_DEV=admin@<ip>` / `GT_BE98_PORT`.
- No `gh` CLI / token. Release uploads rootfs-0031/bootfs-0031 still
  pending (user action; dl-cache pre-seeded locally).

## 2. Current device state (end of last session, 2026-06-06)

- **Slot 2 = br-0034 (RUNNING, COMMITTED, gate 20/20)** = 0031 ASUS rootfs
  + identity marker + v2 in-image dead-man + S27 breadcrumb logger.
- Slot 1 = br-0032 (gate-validated twice) = fallback.
- Factory MAC restored (`et0macaddr/label_mac/lan_hwaddr =
  60:CF:84:38:87:B0`) after the br-0033 poisoning; CFEROM BaseMacAddr is
  the reference. **Verify at session start**: `ip -o link show br0` shows
  60:cf:84:38:87:b0 and `nvram show | grep -c "20:CF:30"` is 0.
- Verify slot state at start: `bcm_bootstate` shows committed 2, valid 1,2;
  booted slot from `/proc/cmdline` (`ubi.block=0,6` = slot 2).

## 3. Safety invariants (absolute, unchanged in spirit, updated facts)

1. Committed slot always holds a gate-validated image (only exception: the
   instant a gate-passed trial is adopted).
2. Trials ONLY via `board/gt-be98/trial/trial-flash.sh` (it encodes the
   verified sequence: hnd-write inactive slot [auto-commits it] → `+G`
   repair → `bcm_bootstate 3` ONCE arm [verify reset_reason=1] → reboot).
   ONCE works on this board (4/4). Never use `bcm_bootstate -N` or states
   5/7. Verify by reading state, never exit codes.
3. The dead-man flag lives on **/data** (rail-mounted at S25; /jffs is
   rc-mounted and arrives too late — br-0033 lesson). Flag is never
   consumed by failure paths; only the operator (you) removes it: PASS →
   gate → rm flag (init self-commit already adopted the slot); FAIL →
   neutralize (flash the current-good artifact over the trial slot, `+G`,
   rm flag).
4. `/proc/bootstate/active_image` LIES — booted slot = cmdline ubi.block.
5. Shared state is sacred: no experimental `nvram commit` (the br-0033 MAC
   poisoning is the cautionary tale — restore-from-backup commits only);
   never touch loader/U-Boot env; **never reuse the envrams wrapper**
   (banned, `m4-staging/README.md` — it caused BSP-MAC fallback +
   persistent nvram poisoning). envrams retirement = kill+firewall only.
6. Only images reusing the proven 0031 bootfs. Kernel/bootloader from
   source stays DEFERRED.
7. Outage discipline: ≤3 trial cycles/day; prefer evening; always end the
   session on a validated committed image with no armed flags.
8. Device dark after a reboot: do nothing destructive; first suspect the
   VANTAGE (lease churn + firewall — nmap sweep, check from operator
   subnet evidence in journal), then wait out dead-man window (+300s) +
   boot; probe ≥2 h; the metadata guarantees any power event boots the
   committed good slot. Write the incident in the journal either way.

## 4. Harness (proven; in `gt-be98-buildroot/board/gt-be98/`)

- `trial/trial-flash.sh --reboot --window 300 <pkgtb>` — full trial driver
  with preflight/verification at every step. After "TRIAL SLOT IS UP":
  disarm via `ssh … 'touch /tmp/deadman-disarm'` (you have ~300 s from
  services-start; automate the disarm on first SSH answer).
- `trial/gate-check.sh --expect-slot N --expect-sha <release-string>` —
  the §5 validation gate (20 checks incl. 3-min soak; `--quick` skips
  soak). dnsmasq is NOT expected on this AP.
- Trial images carry the dead-man in-image (S26) + breadcrumbs (S27 →
  `/data/boot-breadcrumb.log`, snapshots from ~uptime 9 s, `.prev` =
  previous boot). **Read breadcrumbs after every trial — they are the
  forensics for any slow/failed boot.**
- `rootfs-transform.sh` consumes `rootfs-remove.list` (typo-guarded),
  `rootfs-rename.list`, `rootfs-overlay-full/`; `rootfs-diff.sh old new
  <host-unsquashfs>` is the mandatory local proof before any flash
  (expected: ONLY the intended ADDED/REMOVED/CHANGED entries).

## 5. M4 slice plan (inputs parked in `board/gt-be98/m4-staging/`)

Method per slice (one coherent ≤5-removal group, one variable per trial):
copy the slice's lines into `board/gt-be98/rootfs-remove.list` → bump
RELEASE → commit → build → `rootfs-diff.sh` proof → trial → disarm → gate
(generic + slice-specific: removed daemons absent, nothing respawning, no
exec-failure spam in dmesg/syslog, webui :8080 alive) → rm flag → journal
(+ size delta + removed-file manifest) → backups. On FAIL: read
breadcrumbs, neutralize with the PREVIOUS good artifact, journal the
culprit candidates.

Suggested slice order (bisects br-0033's unknown culprit):
1. `/usr/sbin/infosvr /usr/sbin/awsiot /usr/sbin/mastiff /usr/bin/asd /usr/sbin/wsdd2`
2. `/usr/sbin/networkmap /usr/networkmap /usr/sbin/uamsrv` (uamsrv is a
   lighttpd symlink)
3. `/usr/sbin/cfg_server /usr/sbin/wlc_nt /usr/sbin/lldpd`
4. amas rc-symlinks: `/sbin/amas_lanctrl /sbin/amas_portstatus
   /sbin/amas_ssd_cd /sbin/conn_diag` (+ optionally the re_mode-only crew
   in a 5th slice: amas_bhctrl amas_ssd amas_status amas_misc
   amas_wlcconnect)
5. `/usr/sbin/bsd /sbin/roamast`
KEEP: wanduck (RUNNING — its gate never landed in 0031; needs its own
investigation before any action), usbmuxd, amas_ipc, amas_lib, ALL shared
libs, httpd/webUI (last, only after webui-go admin path is re-validated).
NO envrams wrapper (§3.5).

If a slice fails the same way twice, park it (journal why) and continue
with the next slice. If the br-0033 culprit is found, write a dedicated
root-cause section in the journal.

## 6. M5 (after M4, or if M4 is parked)

Per `gt-be98-docs/plans/init-migration-go-no-go.md`: rc stays PID1.
New Buildroot packages install under `/opt/br` (or static), wired via the
boot rail (S-scripts) — never clobber the ASUS lib closure. Toolchain
ceiling gcc 10.3/glibc 2.32 (GCC-11+ packages can't build — take from ASUS
blobs or skip). Candidate order: updated dropbear (parallel listener on a
test port first), busybox-owned-by-Buildroot, openssl + dependents,
lighttpd/webui-go serving. Each = its own trial cycle with a
package-specific gate check.

## 7. Continuous duties

After every milestone: journal entry, AGENTS.md state stamp, commit all
repos, refresh `~/be98/device-backups/<date>/` (nvram, /jffs tar, ps).
Maintain the pending-user-actions list (release uploads). Final report:
what shipped, proven vs assumed, incidents, next backlog.
