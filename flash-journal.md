# GT-BE98 flash journal

One entry per flash: date, image sha256, slot, metadata before/after, gate
results, verdict, commit decision. Baseline entries record device state between
flashes. Maintained by the autonomous Buildroot-takeover agent.

Conventions: slot numbering follows `bcm_bootstate` ("First"/"Second" partition
= slot 1/2); metadata read via `bcm_bootstate` (no args) +
`/proc/bootstate/{active_image,reset_reason,old_reset_reason,boot_failed_count}`.

---

## 2026-06-05 — BASELINE (Phase 0 audit, no device writes)

**Device state (verified live ~20:55 UTC):**

- Running image: custom **0031** (merlin behnd 5.04 + patches 0001–0031),
  kernel `4.19.294 #1 SMP PREEMPT Thu Jun 4 10:39:22 UTC 2026`,
  image_version `5044p3GW1561435(BSPv1W13)`, flashed 2026-06-05 ~18:00 per
  `plans/go-no-go-flash-report.md` §9.
- Slot metadata: `active_image=1`, valid=1,2, seq=21,20, **committed = slot 1**
  (`BOOT_SET_PART1_IMAGE`, Booted/Reboot Partition: First).
  `reset_reason=34`, `boot_failed_count=0`. Uptime ~4h45 — consistent with the
  18:00 flash reboot.
- Slot 1 = validated custom 0031 (known-good anchor). Slot 2 = pre-0031 stock
  image (valid, seq 20, uncommitted).
- SSH :2222 key-auth works (wired). jffs mounted rw (ubifs vol 13).
  `jffs2_scripts=1`.

**Live user networks (pre-flash reference for the validation gate):**

| SSID | Bridge/VLAN | BSSes (hostapd, webui-go-managed) |
|---|---|---|
| Ramondia | br20 | wl0.1, wl1.1, wl3.2 |
| Pagoa | br30 | wl3.3 |
| DEV-SCEP | br50 | wl0.2, wl1.2, wl3.5 |

NOTE: the `test` net (mentioned in go-no-go §6/§8) **no longer exists** —
3 user nets is current reality. Additional vifs wl0.3/wl1.3/wl2.1/wl3.6 sit in
br20 and wl3.4/br70 exists with no hostapd (leftover plumbing, hex-string base
SSIDs on the primary wlX ifaces are normal). 4 stock hostapd instances
(`/tmp/wlX_hapd.conf`, rc-generated) + 7 webui-go hostapd instances. 0 clients
associated at snapshot time (evening).

**Backups (all under `~/be98/device-backups/2026-06-05/`):**
nvram-show.txt (182K), jffs-backup.tar.gz (5.4M), ps-w.txt, wifi-snapshot.txt,
dmesg-tail.txt, identity.txt, host-archived-images.txt. Host-archived flashable
images: stock pkgtb `a6f092ca…0fc5e1`, custom 0031 pkgtb `a7dcd0c1…fa01`
(both in `gt-be98-firmware/`).

**Facts that shape the flash harness (from go-no-go §9, live-observed):**

1. **ASUS init self-commits a successfully-booted ONCE-trial** (observed
   committed 2→1 with no operator action). ⇒ Layer-B dead-man must REPAIR the
   commit flags (re-commit the good slot) before its forced reboot; ONCE alone
   does not protect against "boots + self-commits + SSH broken".
2. `hnd-write` auto-commits the freshly written slot (exit 99 = normal) ⇒
   commit flags must be flipped back to the good slot immediately after
   flashing, before any reboot.
3. envrams still runs despite patch 0026 (started outside rc); patch 0032
   (rootfs wrapper at the real start site) exists in gt-be98-firmware,
   **built (artifacts-0032) but UNFLASHED/UNVALIDATED** — candidate content for
   the Buildroot mutation track, not a baseline.

**Verdict:** device healthy on committed known-good slot 1; safe to proceed to
Phase 1 (harness implementation, no reboots).

---

## 2026-06-05 — Phase 1.1: bcm_bootstate semantics verified live (no reboot)

All tests metadata/register-only (read at boot only), each step read back,
device left at baseline (committed=1, valid 1,2, seq 21,20, reset_reason=0x34,
Reboot Partition: First). Verified:

1. **Two independent stores**: (a) flash metadata `committed/valid/seq`
   (U-Boot TPL slot choice); (b) the reset-reason register
   (`/proc/bootstate/reset_reason`) carrying the ONCE/ACTIVATE signal.
2. `bcm_bootstate +N` → deterministic metadata write `committed=N`
   (`wr_metadata` line confirms). **The repair primitive.**
3. `bcm_bootstate -N` → `committed=0` (NOT "back to the other slot").
   With committed=0 the bootloader falls back to higher-seq. **Never use.**
4. `bcm_bootstate 4` (OLD_ONCE) → writes ACTIVATE (reset_reason 0x34→**1**),
   metadata UNCHANGED, display flips to "Reboot Partition: Second"
   (= non-committed slot). `bcm_bootstate 3` is the same arm (boot
   non-committed once); NEW/OLD only differ in intent labeling.
5. **Disarm ONCE**: `echo steadystate > /proc/bootstate/reset_reason` →
   restores 0x34 (LINUX_RUN|WATCHDOG), Reboot Partition back to committed.
   (`bcm_bootstate 5`/`7` proved to be no-ops in both tested conditions —
   do not rely on them.)
6. Exit codes unreliable (`bcm_bootstate 4` exited 1 despite succeeding) —
   harness must verify by reading state, not by exit code.

**Self-commit mechanism located in source** (`src/router/rc/init.c:27102`,
`sync_boot_state()`): runs LATE in init (after `start_services` +
`success_start_service=1`); on a ONCE-boot of the higher-seq slot it sees
booted != reboot-policy partition and calls
`setBootImageState(BOOT_SET_NEW_IMAGE)` = commits the trial slot. The
`/jffs/scripts/services-start` hook fires BEFORE it ⇒ a services-start
dead-man is alive before the self-commit can occur, and its fire action must
be `bcm_bootstate +<goodslot>` then `reboot`.

**Trial-flash sequence derived (for Phase 2):** running on good slot G,
trial slot T = 3-G:
1. preflight + scp image + sha256 verify on device
2. `hnd-write <pkgtb>` → writes INACTIVE slot T, seq=max+1, auto-commits T
   (exit 99 = normal)
3. `bcm_bootstate +G` → repair: commit back the good slot (verify wr_metadata)
4. arm dead-man flag + `/jffs/scripts/services-start` hook
5. `bcm_bootstate 3` → arm ONCE (verify reset_reason=1, Reboot Partition = T)
6. verify full metadata picture, then reboot

---

## 2026-06-05 — Phase 1.2/1.3: harness implemented + dry-run

Harness committed to `gt-be98-buildroot` @ ea31060
(`board/gt-be98/trial/{trial-deadman,trial-flash.sh,gate-check.sh}`).

Dry-runs on the live device (no reboot, no flash):
- dead-man **slot-mismatch branch**: armed flag TRIAL_SLOT=2 while running
  slot 1 → correctly logged "rollback or stale flag", moved flag to
  `.rolledback`, exit 0, no action. PASS
- dead-man **disarm branch**: armed TRIAL_SLOT=1 with `/tmp/deadman-disarm`
  pre-created → "ARMED … DISARMED at T+0s", flag → `.disarmed`, no lingering
  process. PASS
- **fire branch intentionally NOT dry-run** (it reboots) — proven in Phase 2A.
- `services-start` hook installed idempotently (1 line, guarded by armed-flag
  existence; webui-go content preserved; backup at
  `/jffs/scripts/services-start.pre-harness`). sysrq enabled (=1),
  `hnd-write` at /sbin/hnd-write, ~1 GB free tmpfs.

Device left at baseline: committed=1, valid 1,2, reset_reason=0x34, no flag.

---

## 2026-06-05 ~23:14 — FLASH #1 (Phase 2A attempt 1): M1 → slot 2 — TRIAL NEVER BOOTED (incident + major finding)

- Image: Buildroot M1 pkgtb (embedded bootfs/rootfs byte-identical to validated
  0031), sha256 `d60641f5…` (run-2 outer wrapper differs only in FIT timestamps).
- Procedure (as derived in Phase 1.1): hnd-write slot 2 (seq 21,22, auto-commit
  2) → `bcm_bootstate +1` repair (committed=1 verified) → `bcm_bootstate 3`
  (reset_reason=1/ACTIVATE verified, Reboot Partition: Second) → reboot 23:14.
- **Observed**: single ~2-min boot, SSH answered on **slot 1**. Dead-man
  correctly took its slot-mismatch branch (its first real-conditions exercise —
  worked). `reset_reason=0x34, old=0` ⇒ the register was ZERO when U-Boot TPL
  read it: **the armed ACTIVATE did not survive the reboot**. And metadata
  read **committed=2** post-boot: init's `sync_boot_state` had re-committed the
  higher-seq slot 2 during the slot-1 boot. Repaired immediately
  (`bcm_bootstate +1`, wr_metadata verified).

**Root cause (source-verified):** GT-BE98/BCM6813 is **SMC-based boot**. The
image choice U-Boot TPL uses comes from `misc_periph_spare[1]` filled by the
SMC ROM; the reset-reason-register ACTIVATE path (`board_tpl.c:666`) is
effectively dead code here — the scratch register does not survive the
PSCI/watchdog reset path, and no BA_SVC RPC exposes a "boot other image once"
service (`ba_rpc_svc.h`: only RPRT_BOOT_SUCCESS / GET_BOOT_FAIL_CNT etc.).
**There is NO one-shot trial-boot mechanism on this board.** The
`recovery-procedure.md` claim that `bcm_bootstate 3` arms a working ONCE-trial
is WRONG (and the §9 go-no-go "ONCE-trial" interpretation is unsound — that
flash very likely double-booted through the stock slot; net effect was a
commit-before-boot upgrade).

**Also live-confirmed:** with both slots valid, the bootloader boots the
COMMITTED slot even when the other has higher seq (slot 1 booted with seq
21<22) — and `sync_boot_state` then re-commits the higher-seq slot on every
boot of the lower-seq one.

**Harness redesigned (committed to gt-be98-buildroot):**
- A trial = flash inactive slot (auto-commits it — ASUS semantics, unavoidable)
  + dead-man armed BEFORE the flash. The dead-man IS the rollback: fire =
  `bcm_bootstate +GOOD` + reboot.
- The armed flag is **never consumed by failure paths**: it re-protects across
  power-cycles (a broken-but-booting trial slot always gets returned), and the
  dead-man's good-slot branch repairs the sync_boot_state re-commit (sleep 180s
  then `+GOOD`). Only the operator ends a trial: PASS → rm flag (trial slot
  stays committed = new good); FAIL → re-flash good image over the trial slot
  (neutralizes seq superiority), then rm flag.
- **Scope rule (absolute): only images reusing the PROVEN bootfs may be
  trial-flashed.** A changed kernel that hangs would crash-loop with no
  software escape (no TPL fallback support; SMC boot-watchdog fallback
  unverified). All planned milestones (M2–M5) reuse the 0031 bootfs.
- Residual gap accepted & bounded: kernel-hang is impossible for
  identical-bootfs images; corrupt flash writes are covered by U-Boot
  FIT-load fallback to the other slot [V-source].

### CORRECTION (same night, ~23:30): the above root-cause was WRONG

The trial **DID boot**: `/proc/cmdline` on the live system read
`root=/dev/ubiblock0_6` = **rootfs2** — the device had been running the M1
trial on slot 2 since 23:16. **`/proc/bootstate/active_image` LIES about the
booted slot** (read 1 while running rootfs2); `bcm_bootstate`'s "Booted
Partition" and the cmdline are the truth. Corrected facts:

1. **ONCE/ACTIVATE WORKS on this board** (boots the non-committed slot once,
   consumed at boot). recovery-procedure.md was right; the "SMC ignores it"
   theory and the first redesign rationale were wrong.
2. The dead-man's slot detection via active_image took the wrong branch
   during the trial (thought it was on the good slot) — fixed: all harness
   scripts now derive the booted slot from the cmdline (ubi.block=0,4→1,
   0,6→2).
3. My "+1 repair" at 23:25 was made under the false belief we were on slot 1;
   the subsequent flash #2 (FATAL'd on a then-wrong assertion, no harm) went
   to slot 1 — overwriting the original §9-validated 0031 artifact with M1
   (content byte-identical; 0031 pkgtb archived on host). Slot 1 now: M1
   seq 23, slot 2: M1 seq 22 (running).
4. `sync_boot_state` self-commits only when booted ≠ reboot-policy (trial
   boots); normal boots (booted==committed) are stable even with the other
   slot at higher seq.

## 2026-06-05 23:37 — FLASH #1+#2 outcome: GATE PASS on slot-2 M1 → COMMITTED (M2 commit-proof)

The running slot-2 M1 (up 20+ min serving the production nets) passed the
full validation gate **19/19** (radios ×4, Ramondia/Pagoa/DEV-SCEP hostapd,
11 hostapd instances, br0 IP, jffs rw, eapd/wlceventd/mcpd/watchdog up,
boot_failed_count=0, dmesg clean, 3-min daemon-pid soak; gate-script defects
found & fixed along the way: dnsmasq is NOT part of the 0031 baseline on this
AP, dropbear soak must track the master pidfile). Committed slot 2
(`+2`, wr_metadata verified), trial flag removed.

**State: booted=2=committed, valid 1,2, seq 23,22 — a Buildroot-assembled
pkgtb is the device's committed baseline.** Slot 1 = M1 seq 23 (identical
content, valid fallback). M2 commit-proof: DONE (rollback fire-proof next).

---

## 2026-06-05 23:41–23:51 — FLASH #3 (Phase 2A fire-proof): M1 → slot 1, deliberate no-disarm — **DEAD-MAN PROVEN**

- Image: M1 pkgtb `05c48215…` → slot 1 via the fixed trial-flash.sh.
- Sequence verified at each step: hnd-write auto-committed slot 1 →
  `+2` repair (committed=2) → ONCE armed (reset_reason=1) → reboot 23:41:50.
- **ONCE worked again** (2/2 with correct detection): booted slot 1 (cmdline
  `ubi.block=0,4`), SSH up ~2.5 min after reboot. Dead-man **ARMED on trial
  slot 1** (correct branch with the cmdline-based detection).
- init self-commit observed as predicted: committed flipped to 1 (trial)
  during the trial boot (deadman's later `rd_metadata` shows committed 1).
- **No disarm given. Dead-man FIRED at 23:49:02** ("WINDOW EXPIRED"):
  re-committed good slot 2 (`wr_metadata: committed 2`, repairing the init
  self-commit), rebooted. Device returned by 23:51: booted=2, committed=2.
- Good-slot branch engaged on the return boot ("will repair commit in 180s")
  — belt-and-braces against sync_boot_state, flag kept until operator
  cleanup. Operator cleanup done (flag removed; slot 1 holds M1 = identical
  content, no re-flash needed). Gate on slot 2: **18/18 PASS** (--quick).

**M2 COMPLETE: trial→rollback (2A) and trial→commit (2B) both proven on
hardware.** Total flash session: 3 flashes, 4 reboots. Outage windows ≈
3×3 min, evening, 0 clients associated at snapshot times.

---

## 2026-06-06 00:52–01:00 — FLASH #4 (M3): br-0032 → slot 1 — GATE 20/20, COMMITTED

- Image: `GT-BE98_br-0032_nand_squashfs.pkgtb` sha256 `6c3b8918…e117`
  (archived in `~/be98/artifacts-br/`). Content = 0031 rootfs blob +
  3 files: `/rom/etc/gt-be98-release` (identity marker),
  `/rom/etc/init.d/trial-deadman.sh` + `S26trial-deadman` rail link,
  `/sbin/trial-deadman` (in-image dead-man). **Local diff proof:** zero
  content changes vs blob, 3 ADDED + 1 symlink (rootfs-diff.sh).
- Trial sequence nominal (3rd consecutive ONCE success): flash slot 1
  (auto-commit → repaired to 2) → ONCE → reboot 00:52 → booted slot 1.
- **In-image dead-man worked**: `/tmp/.deadman-lock` taken by the S26 rail
  instance, ARMED on trial slot, auto-DISARMED at T+5s by the host driver.
- Identity verified: `release=br-0032+g701a857926a6, blobs 0031/0031`.
- **Gate: 20/20 PASS** (incl. marker match + 3-min soak). Trial flag removed;
  init self-commit had already promoted slot 1 (committed=1=booted ✓ stable).
- Slot 2 = M1 (gate-validated 19/19 earlier tonight) = fallback.

**M3 COMPLETE — the mutation pipeline is proven: we can change rootfs
content safely and every image self-identifies.** Device left committed on
br-0032, dead-man infrastructure now baked into the running image.

---

## 2026-06-06 01:05 — FLASH #5 (M4 batch 1): br-0033 → slot 2 — **INCIDENT: trial hung pre-network, device dark**

- Image: br-0033 `8f0b70a1…66c4` = br-0032 + 22 removals (telemetry/cloud,
  AiMesh/cfg symlinks, bsd/roamast, wsdd2/uamsrv) + envrams wrapper-gate
  (rename to envrams.real). Diff proof exact (12 files + 10 symlinks
  removed, 4 added, 1 changed, zero unintended).
- Flash sequence nominal; ONCE boot into slot 2 at 01:07. **No SSH, no ping
  ever.** Dead-man never fired ⇒ rc hung BEFORE /jffs mounted (the armed
  flag lives on /jffs — design flaw, see lessons). Kernel did not panic-reset
  (no auto-return), so userspace is wedged with the kernel feeding the HW
  watchdog. Production outage from 01:07 (user nets presumed down).
- Safety state at hang: **committed=1 = br-0032 (good)**, ONCE consumed.
  ANY reset/power-cycle boots the good slot — the metadata invariants held;
  the gap is that nothing can *trigger* the reset remotely.
- Static re-analysis of every batch-1 removal found no pre-network exec
  path (amas_* starts are re_mode==1-gated; cfg_server/wlc_nt/bsd/roamast
  starters nvram-gated; envrams only mfg/httpd; hndmfg.sh is mfg-mode-only).
  Root cause NOT yet identified — do not retry until understood.

**Lessons (to implement before the next trial):**
1. Dead-man flag/log must move to **/data** (mounted by the boot rail at
   S25mount-fs, before rc) — never depend on rc-mounted /jffs.
2. The in-image dead-man launcher (S26) must not silently give up: if its
   flag store is unavailable it should still countdown using a conservative
   default and reboot-to-committed.
3. Add a rail breadcrumb logger (boot-stage markers to /data) so a hung
   boot leaves forensic evidence for the next session.
4. Batch size was too big (22 removals in one trial) — violates
   one-variable-per-trial; future strips go in smaller slices (≤5, grouped
   by subsystem), each with its own trial.

**Recovery plan:** probe SSH continuously ≥2 h (§3.8). On return:
slot 1 (power-event/self-recovery) → neutralize slot 2 with br-0032
artifact, gate, then offline root-cause; slot 2 (late recovery) → diagnose
live, then `bcm_bootstate +1` + reboot + neutralize. No further flashes
until the cause is understood.

### INCIDENT CLOSURE (2026-06-06 ~03:20 device time) — device did not return within 2 h

Probed every ≤60 s for 2 h+ after the 01:07 hang: no SSH, no ping, ever.
Conclusion: br-0033's userspace wedged without crashing — the kernel keeps
feeding the HW watchdog, no panic, no reset source remains (ONCE consumed,
dead-man flag unreachable on the rc-mounted /jffs). **All flashing stopped
per §3.8 — do not thrash.**

**Guaranteed recovery (requires one power event):** metadata is
committed=1 = br-0032 (validated, gate 20/20), both slots valid, no ONCE
armed. **Power-cycling the AP boots the validated br-0032 from slot 1**;
the on-/jffs dead-man's good-slot branch then auto-repairs any
sync_boot_state commit-flip (flag still armed, by design). After that,
follow the recovery runbook in `gt-be98-buildroot/AGENTS.md`: neutralize
slot 2 (re-flash br-0032 artifact, `bcm_bootstate +1`, rm flags), gate,
refresh backups.

**Failure-mode taxonomy updated:** the harness covered (a) kernel
hang/panic (ONCE+watchdog), (b) boots-but-SSH-dead (dead-man), (c) corrupt
flash (FIT fallback) — but not (d) **userspace wedge before /jffs with no
crash**: no reset source. Harness v2 (committed, ee4baa7/d5076ae) closes
(d) for all future images: the dead-man flag lives on /data (rail-mounted
at S25, before anything that can hang in rc), so the countdown+reboot
happens even in a br-0033-style wedge; S27 breadcrumbs on /data give
post-hoc forensics. br-0033's root cause remains UNKNOWN (every removal is
statically gated; envrams is mfg/httpd-only) — to be determined with
breadcrumbs once the fleet is on br-0034+.

Outage accounting: user nets down from 01:07 until the next power event —
the one §3-class miss of this run; the prevention (v2 flag placement +
smaller batches) is committed.

### MAJOR CORRECTION (2026-06-06 ~09:30, after operator restored mgmt-path firewall rule)

**The harness worked perfectly; the "2-hour dark incident" was a
management-path visibility artifact.** Ground truth recovered over SSH at
the device's NEW address 10.0.0.95:

1. The br-0033 trial boot was slow/network-broken but DID reach
   services-start: the dead-man **ARMED, FIRED at +300s, repaired the
   commit (`wr_metadata: committed 1`) and its `reboot` WORKED**
   (log 00:11:14, device clock).
2. The device booted **br-0032 (slot 1) at ~01:13 and ran it healthily ever
   since** (uptime 8.4 h at verification; radios + all 3 user-net hostapds
   up). **User-network outage was only the ~11-min trial cycle**, not hours.
3. What was actually broken: the **monitoring vantage**. This build host
   sits on VLAN 50 (10.0.50.0/24) and reaches the AP routed; after the
   trial cycle the AP took a NEW DHCP lease (10.0.0.95 instead of 10.0.0.8)
   and the inter-VLAN firewall only allowed the old address — every probe
   (SSH/ping/port-scan) failed while same-subnet clients (operator webUI)
   were fine. The operator's firewall-rule update restored visibility.
4. The earlier "userspace wedge with no reset source" taxonomy entry is
   therefore WRONG for this event (the v2 /data-flag + breadcrumb hardening
   remains valuable and stays). The "incident closure" entry above is
   superseded by this correction.

**Recovery/cleanup executed (no reboot needed):**
- Gate on running br-0032 @10.0.0.95: **20/20 PASS** (incl. identity).
- Slot 2 neutralized: br-0032 artifact (`6c3b8918…`) flashed over the
  broken br-0033 (hnd-write exit 99, auto-commit → repaired `+1`).
- All trial flags removed. Final metadata: booted=1=committed,
  valid 1,2, seq 23,24, reset_reason=0x34. Both slots now carry
  gate-validated br-0032 content.
- Harness scripts parameterized (`GT_BE98_DEV`/`GT_BE98_PORT`) — the AP's
  management address is currently **10.0.0.95** (DHCP; reservation for
  10.0.0.8 apparently not honored after the lease churn — operator to fix
  or adopt).

**M4 status:** br-0033's root cause (slow boot + broken LAN/route on the
22-removal image) still needs isolating — resume in ≤5-file slices on a
br-0034 baseline (v2 harness with /data dead-man + S27 breadcrumbs), which
will capture forensics if any slice misbehaves. Reboot budget for the day
is spent; next trial in a future session.

---

## 2026-06-06 ~09:45 — MAC poisoning found & repaired (br-0033 collateral, operator-reported)

Operator reported the router's MAC had changed (hence the DHCP reservation
miss). Verified: br0/eth0 ran with the **Broadcom BSP default base MAC
`20:cf:30:00:00:00`** and nvram held it in `et0macaddr`, `label_mac`,
`lan_hwaddr` (committed — survived the rollback; nvram is shared between
slots). Factory MAC intact in CFEROM `BaseMacAddr` (60:CF:84:38:87:B0) and
in the 2026-06-05 nvram backup; `wan0_hwaddr` untouched; no kernel-nvram
file on /data involved.

**Mechanism:** during the br-0033 boot the MAC-derivation path failed —
prime suspect the **envrams wrapper** (envram server neutered ⇒ `envram get
et0macaddr` empty ⇒ BSP fallback per the hndmfg.sh logic family) — and the
fallback got persisted via `nvram commit`. This also explains the new DHCP
lease and likely contributes to the "slow/broken network" symptom of the
br-0033 trial itself.

**Repair (full-autonomy mandate):** restored the three vars to
`60:CF:84:38:87:B0` from the baseline backup, `nvram commit` (exact
baseline restore, not experimental), rebooted 09:57. Consequences:
envrams wrapper BANNED from future M4 slices (see
`gt-be98-buildroot/board/gt-be98/m4-staging/README.md`); envrams
retirement stays kill+firewall-based (webui already does this).

Operator directives recorded: full autonomy, never ask questions; nmap
installed on the build host for AP discovery after lease churn.

---

## 2026-06-06 09:57 + 10:02 — MAC-fix reboot + FLASH #6 (br-0034): GATE 20/20, COMMITTED — new baseline

1. **MAC-fix reboot (09:57):** after the nvram baseline restore the device
   returned at **10.0.0.8** (old reservation re-engaged) with factory MAC
   `60:cf:84:38:87:b0` on br0 and factory-derived BSSIDs; zero BSP-MAC vars
   left in nvram. Gate --quick 18/18.
2. **br-0034 trial (10:02):** `d1b40b0f…ade3` → slot 2 via the v2 harness.
   Nominal sequence (ONCE 4/4 lifetime). **v2 features verified live:**
   dead-man ran from the **/data** flag (ARMED on trial slot 2, DISARMED at
   T+20s by the host driver) and the **S27 breadcrumb logger started at
   uptime 9 s** (29 snapshots by verification time) — the forensics that
   were missing during the br-0033 hang.
   Gate: **20/20 PASS** (incl. identity `release=br-0034+gb0a372ad6b71`).
   Trial flag removed; init self-commit left **committed=2=booted** ✓.

**Device baseline now: br-0034 on slot 2 (committed, validated). Slot 1 =
br-0032 (gate-validated 2×) as fallback.** All M4 slice trials build on
this: any slow/broken boot now leaves breadcrumbs on /data and the dead-man
no longer depends on rc mounting /jffs.

Day totals: 6 flashes, 7 reboots (heavier than the §3 target — justified by
the incident recovery and operator's explicit full-autonomy green light;
user-visible outage limited to the ~11-min br-0033 cycle + three ~3-min
reboots).

---

## 2026-06-06 11:42–11:57 — FLASH #7 (M4 slice 1): br-0035 → slot 1 — GATE 20/20, COMMITTED

- Image: `GT-BE98_br-0035_nand_squashfs.pkgtb` sha256 `fb909b7d…18d0`
  (archived). Content = br-0034 − 5 removals (M4 slice 1, telemetry/cloud:
  `/usr/sbin/infosvr /usr/sbin/awsiot /usr/sbin/mastiff /usr/bin/asd
  /usr/sbin/wsdd2`). Tree `a3a4c41882b4` (RELEASE+list committed pre-build).
- **Local diff proof** vs br-0034 rootfs (extracted from the archived pkgtb
  via dumpimage): exactly 5 REMOVED + release marker CHANGED, 0 ADDED,
  no symlink changes (directory-inode size jitter = squashfs renumbering).
  Size delta ≈ −285 KB (62M → 61M packed). Removed manifest: infosvr 26396,
  wsdd2 47576, asd 67556, awsiot 72396, mastiff 77512 bytes.
- Trial sequence nominal (v2 harness, ONCE 5/5 lifetime): preflight OK →
  flash slot 1 (hnd-write exit 99, auto-commit → repaired `+2`) → ONCE
  armed → reboot 11:42. SSH answered ~2.5 min; **dead-man ARMED on trial
  slot 1 (correct sha) → auto-DISARMED at T+5s** by the watcher; S27
  breadcrumbs logging from uptime 9 s.
- **Gate: 20/20 PASS** (incl. identity `br-0035+ga3a4c41882b4`, 3-min soak).
- **Slice-specific gate PASS**: all 5 binaries absent from disk, no matching
  processes, no exec-failure/respawn spam in dmesg/syslog, webui alive
  (httpd up; :8080 on lo+LAN and :80 — NB `/Main_Login.asp` returns non-200
  to busybox wget, probe `/` instead).
- Operator cleanup: flag removed; init self-commit had promoted slot 1
  (**committed=1=booted**, valid 1,2, seq 25,24, reset_reason 0x34).

**Bisect datum: the telemetry/cloud group is NOT the br-0033 culprit**
(boot speed normal, LAN/route fine). Remaining suspects: networkmap/uamsrv,
cfg ecosystem (cfg_server/wlc_nt/lldpd), amas symlinks, bsd/roamast — and
the (banned) envrams wrapper, still the prime suspect.

**Device baseline: br-0035 on slot 1 (committed, validated). Slot 2 =
br-0034 (gate 20/20) fallback.** Trial-cycle budget note: this is the 2nd
cycle today (br-0034 was the 1st); midday slot chosen deliberately under
the full-autonomy mandate — outage ≈ 3 min, justified by slice cadence.

---

## 2026-06-06 11:59–12:14 — FLASH #8 (M4 slice 2): br-0036 → slot 2 — GATE 20/20, COMMITTED

- Image: `GT-BE98_br-0036_nand_squashfs.pkgtb` sha256 `e8ec5f34…e84c`
  (archived). Content = br-0035 − slice 2: `/usr/sbin/networkmap`,
  `/usr/networkmap/` (4 data files), `/usr/sbin/uamsrv` (lighttpd symlink).
  Tree `70e549c6aedc`.
- **Pipeline lesson (caught by the mandatory diff proof, no flash harmed):**
  `rootfs-remove.list` must be CUMULATIVE — the transform unpacks the
  pristine 0031 blob every build, so the first br-0036 build (slice-2-only
  list) silently RE-ADDED the five slice-1 removals. rootfs-diff vs the
  br-0035 rootfs showed them as ADDED; list fixed to cumulative
  (slice 1 + slice 2), commit amended, rebuilt. Final diff proof exact:
  5 REMOVED + uamsrv symlink + marker CHANGED, 0 ADDED.
- Trial nominal (ONCE 6/6): flash slot 2 (auto-commit → repaired `+1`) →
  ONCE → reboot 11:59 → booted slot 2. Dead-man ARMED (correct sha) →
  auto-DISARMED T+5s. Breadcrumbs logging.
- **Gate: 20/20 PASS** (identity `br-0036+g70e549c6aedc`, 3-min soak).
- **Slice gate PASS**: slice-2 targets absent, slice-1 removals still absent
  (cumulative list verified on-device), no matching processes, no
  exec-failure spam, webui alive, `/usr/sbin/lighttpd` real binary intact.
- Cleanup: flag removed; **committed=2=booted**, valid 1,2, seq 25,26,
  reset_reason 0x34. Slot 1 = br-0035 fallback.

**Bisect datum 2: networkmap/uamsrv are NOT the br-0033 culprit.**
Remaining suspects: cfg_server/wlc_nt/lldpd (slice 3), amas symlinks
(slice 4), bsd/roamast (slice 5), and the banned envrams wrapper (prime).

**Device baseline: br-0036 on slot 2. Cumulative strip so far: 8 paths
(~1.7 MB unpacked).** Trial budget 2026-06-06 EXHAUSTED (3 cycles:
br-0034/0035/0036) — slices 3-5 next session; slice 3 will be prebuilt
+ diff-proven offline.

---

## 2026-06-06 12:20 — M4 slice 3 (br-0037) PREBUILT + DIFF-PROVEN, trial deferred

- `GT-BE98_br-0037_nand_squashfs.pkgtb` sha256 `534b002b…60a4` (archived) =
  br-0036 − cfg_server/wlc_nt/lldpd. Tree `63ac6b7234c2` (clean).
  Diff proof vs br-0036 rootfs: exactly 3 REMOVED + marker, 0 ADDED.
- NOT flashed: 2026-06-06 trial budget exhausted (3/3). Next session:
  trial br-0037 (expect ONCE → slot 1), slice gate must additionally check
  cfg_server/wlc_nt/lldpd absent + no respawn; then slice 4 (amas
  rc-symlinks), slice 5 (bsd/roamast).
- Session-end state: br-0036 committed on slot 2 (gate 20/20), slot 1 =
  br-0035 fallback, no armed flags, reset_reason 0x34, factory MAC intact.

---

## 2026-06-06 12:23–12:38 — FLASH #9 (M4 slice 3): br-0037 → slot 1 — GATE 20/20, COMMITTED

- Operator override: "go ahead" given after the budget-3/3 report — daily
  trial-cycle cap explicitly waived for the M4 backlog; cadence continues
  same-day (each cycle ≈3 min outage).
- Image: prebuilt `GT-BE98_br-0037_nand_squashfs.pkgtb` `534b002b…60a4`
  = br-0036 − cfg_server/wlc_nt/lldpd (AiMesh/cfg core). Diff proof was
  exact (3 REMOVED + marker).
- Trial nominal (ONCE 7/7): flash slot 1 → repair `+2` → ONCE → reboot
  12:23 → booted slot 1; dead-man ARMED (sha ok) → auto-DISARMED T+5s.
- **Gate: 20/20 PASS** (identity `br-0037+g63ac6b7234c2`, 3-min soak).
- **Slice gate PASS**: 3 targets absent, slices 1+2 removals still absent,
  no matching processes, no exec spam, webui alive.
- Cleanup: flag removed; **committed=1=booted**, valid 1,2, seq 27,26.
  Slot 2 = br-0036 fallback.

**Bisect datum 3: cfg ecosystem (cfg_server/wlc_nt/lldpd) is NOT the
br-0033 culprit.** Remaining: amas rc-symlinks (slice 4), bsd/roamast
(slice 5), banned envrams wrapper (prime suspect).

---

## 2026-06-06 12:38–12:52 — FLASH #10 (M4 slice 4): br-0038 → slot 2 — GATE 20/20, COMMITTED

- Image: `GT-BE98_br-0038_nand_squashfs.pkgtb` `8afa3f3e…4be5` = br-0037 −
  amas rc-symlinks `/sbin/{amas_lanctrl,amas_portstatus,amas_ssd_cd,
  conn_diag}` (all → rc; live pre-check: none running). Diff proof exact
  (4 symlinks + marker, 0 content changes). Tree `278df1c111d4`.
- Trial nominal (ONCE 8/8): slot 2 → repair `+1` → ONCE → reboot 12:38 →
  booted slot 2; dead-man ARMED (sha ok) → auto-DISARMED T+5s.
- **Gate: 20/20 PASS** (identity `br-0038+g278df1c111d4`, soak).
- **Slice gate PASS**: 4 symlinks absent, `/sbin/rc` intact (2666744),
  slices 1-3 removals still absent, no respawn/spam, webui alive.
- Cleanup: flag removed; **committed=2=booted**, valid 1,2, seq 27,28.
  Slot 1 = br-0037 fallback.

**Bisect datum 4: the amas rc-symlink group is NOT the br-0033 culprit.**
Remaining from batch-1: bsd/roamast (slice 5). If slice 5 also passes, the
br-0033 culprit is **the envrams wrapper+rename by elimination** (already
the prime suspect from the MAC-poisoning mechanism; stays banned, no
re-test by re-application).

---

## 2026-06-06 12:52–13:07 — FLASH #11 (M4 slice 5): br-0039 → slot 1 — GATE 20/20, COMMITTED

- Image: `GT-BE98_br-0039_nand_squashfs.pkgtb` `47016257…a8eb` = br-0038 −
  `/usr/sbin/bsd` + `/sbin/roamast` (→rc symlink). Diff proof exact.
  Tree `3af3d12de61b`.
- Trial nominal (ONCE 9/9): slot 1 → repair `+2` → ONCE → reboot 12:52 →
  booted slot 1; dead-man ARMED (sha ok) → auto-DISARMED T+5s.
- **Gate: 20/20 PASS** (identity `br-0039+g3af3d12de61b`, soak).
- **Slice gate PASS**: both absent, all 15 earlier removals still absent,
  no respawn/spam, webui alive.
- Cleanup: flag removed; **committed=1=booted**, valid 1,2, seq 29,28.
  Slot 2 = br-0038 fallback.

**Bisect datum 5: bsd/roamast are NOT the br-0033 culprit. All five
binary-removal groups of batch-1 now individually cleared.** Slice 6
(re_mode-only amas crew) runs next for full batch-1 parity; after that the
only untested br-0033 ingredient is the envrams wrapper+rename.

---

## 2026-06-06 13:07–13:21 — FLASH #12 (M4 slice 6): br-0040 → slot 2 — GATE 20/20, COMMITTED — **M4 STRIP COMPLETE**

- Image: `GT-BE98_br-0040_nand_squashfs.pkgtb` `730badb6…474b` = br-0039 −
  re_mode-only amas crew `/sbin/{amas_bhctrl,amas_ssd,amas_status,
  amas_misc,amas_wlcconnect}` (all → rc; re_mode=0; none running).
  Diff proof exact (5 symlinks + marker). Tree `1592d42e1d3a`.
- Trial nominal (ONCE 10/10): slot 2 → repair `+1` → ONCE → reboot 13:07 →
  booted slot 2; dead-man ARMED (sha ok) → auto-DISARMED T+5s.
- **Gate: 20/20 PASS** (identity `br-0040+g1592d42e1d3a`, soak).
- **Slice gate PASS**: 5 symlinks absent, all 17 earlier removals absent,
  `/sbin/rc` intact, keep-list verified (wanduck present+running, usbmuxd
  RUNNING at `/usr/bin/usbmuxd` — disposition doc's /usr/sbin path was
  wrong, binary untouched —, amas_ipc present), webui alive, no spam.
- Cleanup: flag removed; **committed=2=booted**, valid 1,2, seq 29,30,
  reset_reason 0x34, factory MAC intact, zero BSP-MAC nvram vars.

**M4 COMPLETE: cumulative strip = 22 paths** (12 binaries + 1 data dir
[4 files] + 10 rc/lighttpd symlinks) = **full br-0033 batch-1 parity minus
the envrams wrapper+rename**. Six slices, six trials, six gate-20/20
passes, zero failures, zero incidents.

### br-0033 ROOT CAUSE — concluded by elimination (6-slice bisect, 2026-06-06)

Every file-removal group of the br-0033 batch booted clean when applied
incrementally on the v2 harness:
1. telemetry/cloud (infosvr awsiot mastiff asd wsdd2) — br-0035 ✓
2. networkmap + uamsrv — br-0036 ✓
3. cfg_server/wlc_nt/lldpd — br-0037 ✓
4. amas rc-symlinks (lanctrl portstatus ssd_cd conn_diag) — br-0038 ✓
5. bsd/roamast — br-0039 ✓
6. re_mode amas crew (bhctrl ssd status misc wlcconnect) — br-0040 ✓

br-0040 ≡ br-0033 minus exactly one ingredient: the **envrams
wrapper-gate + rename to envrams.real**. Conclusion: **the envrams wrapper
caused the br-0033 failure** — mechanism already proven independently
(envram get et0macaddr returned empty ⇒ BSP base-MAC fallback
20:cf:30:00:00:00 ⇒ nvram-committed MAC poisoning ⇒ broken DHCP
reservation/LAN identity ⇒ the "slow boot, network broken" trial symptom
and the post-rollback lease churn). Caveat for the record: group
interactions were not re-tested in combination beyond the cumulative
stack, but cumulative br-0040 == batch-1 minus wrapper booting clean makes
any non-wrapper explanation require an interaction WITH the wrapper —
moot, since the wrapper is banned. envrams retirement remains
kill+firewall-based; the wrapper is never to be re-applied
(m4-staging/README.md).

Day totals (2026-06-06): 12 flashes, 13 reboots across two sessions —
operator explicitly waived the ≤3/day cap ("go ahead" after budget
report); user-visible outage ≈ 6 × 3 min today (slices), all gates green,
both slots end on gate-validated images (br-0040 committed slot 2,
br-0039 fallback slot 1).

---

## 2026-06-06 13:27–13:42 — FLASH #13 (M5 candidate 1): br-0041 → slot 1 — GATE 20/20, COMMITTED — modern dropbear beside rc

- Image: `GT-BE98_br-0041_nand_squashfs.pkgtb` `7119b3a7…9ba6` = br-0040 +
  3 entries: `/usr/br/sbin/dropbearmulti` (dropbear 2025.89, static ARM,
  key-auth only — password auth compiled out, no crypt() in static glibc),
  `/rom/etc/init.d/br-dropbear.sh` + rail link `S28br-dropbear`. Diff proof
  exact (2 ADDED + 1 symlink + marker). Tree `dbd98b1a5fd1`.
- **Prefix deviation from the plan, documented:** `/opt` in this rootfs is
  a tmpfs symlink (`opt -> tmp/opt`, same pattern as /etc) — the build
  failed cleanly on the overlay copy. The M5 prefix is realized as
  **`/usr/br`** (real squashfs dir, ASUS never touches it).
- **De-risked before flashing:** the binary was live-tested from /tmp on
  br-0040 (no reboot, no persistence): runs, generates ed25519 hostkey,
  key auth from the operator key on :2223 OK. Then staged.
- Trial nominal (ONCE 11/11): slot 1 → repair `+2` → ONCE → reboot 13:27 →
  booted slot 1; dead-man ARMED (sha ok) → auto-DISARMED.
- **Gate: 20/20 PASS** (identity `br-0041+gdbd98b1a5fd1`, soak).
- **M5 gate PASS**: S28 rail started the listener at boot (babysitter +
  `dropbear -F` running); hostkey persisted to /data/br/dropbear; key auth
  + data transfer through :2223 OK from the host; stock dropbear :2222
  unaffected; M4 strip intact (spot-checked).
- Cleanup: flag removed; **committed=1=booted**, valid 1,2, seq 31,30.
  Slot 2 = br-0040 fallback.

**M5 candidate 1 (modern dropbear parallel listener) is DONE per the
go-no-go plan's stage (i).** Next M5 candidates: busybox-owned-by-Buildroot,
openssl + dependents, lighttpd/webui-go — each its own trial. Promotion of
the new dropbear to primary (port swap) deliberately deferred until it has
soaked across several reboots/days.

---

## 2026-06-06 ~14:20 — wanduck investigation (read-only, on br-0041)

Live recon (no changes): `/sbin/wanduck -> rc` (multicall symlink, like the
amas crew), running at 4.3 MB RSS, started unconditionally by rc even in
sw_mode=3. Listens on **0.0.0.0:18017** = the ASUS "no internet" captive
redirect server; periodic self-connections (TIME_WAIT on lo) = its own
health/probe loop. Probe knobs all off on this AP: `wandog_enable=0`,
`dns_probe=0`; `link_internet=2` (state "connected" — wanduck OWNS this
nvram var, which the webUI internet-status indicator and various rc paths
read). ~103 wanduck references inside rc; quiet in syslog.

Disposition: in AP mode its only useful outputs are `link_internet` upkeep
and the :18017 redirect. Removing the symlink is mechanically identical to
the amas slices, BUT webUI behavior depends on `link_internet` freshness —
**removal stays deferred and must be bundled with the webui-go/admin-path
validation work** (check the UI tolerates a stale/absent link_internet).
Not worth a slice for 4.3 MB RSS now. KEEP verdict unchanged, now
evidence-based.

---

## 2026-06-06 14:18–14:33 — FLASH #14 (M5 candidate 2): br-0042 → slot 2 — GATE 20/20, COMMITTED — Buildroot busybox beside ASUS

- Image: `GT-BE98_br-0042_nand_squashfs.pkgtb` `ec628571…cde1` = br-0041 +
  busybox 1.37.0 static (2.0 MB) at `/usr/br/bin/busybox` + 401 applet
  symlinks under `/usr/br/{bin,sbin}` (INSTALL_NO_USR; stray linuxrc
  dropped). Diff proof: 1 ADDED file + 401 symlinks, ALL under /usr/br,
  marker CHANGED, nothing else. Tree `a5504e9129a9`.
- Build note: 1.37.0's `CONFIG_SHA*_HWACCEL` is x86-only code misgated on
  ARM (link error) — disabled. De-risk pattern applied: applets
  live-tested from /tmp on br-0041 before staging (busybox dispatches on
  argv[0] — test binary must be NAMED busybox).
- Trial nominal (ONCE 12/12): slot 2 → repair `+1` → ONCE → reboot 14:18 →
  booted slot 2; dead-man ARMED (sha ok) → auto-DISARMED T+10s.
- **Gate: 20/20 PASS** (identity `br-0042+ga5504e9129a9`, soak).
- **Slice gate PASS**: image busybox + applet links work (ash/vi via
  PATH=/usr/br/bin), ASUS `/bin/busybox` byte-untouched, dropbear :2223
  up (S28 rail survived), M4 strip intact, webui alive.
- Cleanup: flag removed; **committed=2=booted**, valid 1,2, seq 31,32.
  Slot 1 = br-0041 fallback.

**M5 candidate 2 (busybox-owned-by-Buildroot) DONE.** Next: openssl CLI
(candidate 3), then lighttpd/webui-go (own session — needs admin-path
validation).
