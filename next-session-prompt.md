# GT-BE98 Buildroot takeover — session N+2 prompt (M5 finish + promotions)

You are an autonomous agent with **no human in the loop**. Never ask
questions; decide from this prompt + referenced docs + live evidence, pick
the conservative option when unsure, log every decision in
`gt-be98-docs/flash-journal.md`. You may flash, reboot, and modify firmware
under the safety invariants in §3 — they override everything.

## 0. Mission

1. **Verify the dropbear soak** (:2223 since 2026-06-06 13:42) and, if ≥2
   days have elapsed with a healthy listener across the reboots in the
   journal, decide the **promotion** path (do NOT remove stock dropbear in
   the same trial that promotes; promotion = new listener also on a
   primary-class port, stock untouched, separate later slice to retire it).
2. **M5 candidate 4: lighttpd/webui-go serving.** Precondition (its own
   work item): validate the webui-go admin path documented in
   `gt-be98-docs/` (search "webui-go"); only after that, consider the
   httpd strip (LAST per the disposition doc).
3. **Support the patch-0032 decision**: read
   `gt-be98-docs/plans/patch-0032-envrams-real-start.md` INCLUDING the
   ⚠️ ADDENDUM (2026-06-06). Do NOT flash artifacts-0032. If the operator
   has updated the plan since, follow it; the early-boot-allowance wrapper
   (option 1) can be prototyped in the Buildroot pipeline and trialed with
   the mandatory MAC slice-gate (`nvram get et0macaddr` + br0 MAC +
   `nvram show | grep -c 20:CF:30` == 0 BEFORE adopting).
4. Maintain the backlog: wanduck removal stays bundled with webui-go
   validation (journal 2026-06-06 ~14:20, KEEP for now); release uploads
   rootfs-0031/bootfs-0031 still pending (user action).

"Done" = booted, gate passed, committed, journal + AGENTS.md updated,
backups refreshed, repos committed AND PUSHED (operator authorized push).

## 1. Environment (verified 2026-06-06 ~15:00)

- Workspace `~/be98/`: `gt-be98-buildroot/` (THE repo — read `AGENTS.md`
  first), `buildroot-m1/` (build dir), `gt-be98-firmware/`, `gt-be98-docs/`
  (READ flash-journal 2026-06-06 entries: M4 bisect, M5 candidates,
  patch-0032 addendum), `gt-be98-packages/`, `~/be98/artifacts-br/`
  (br-0032..br-0043 archived; br-0033 `8f0b70a1…` QUARANTINED — never
  flash), `~/be98/device-backups/`.
- Build: `cd ~/be98/buildroot-m1 && export BR2_DL_DIR=~/be98/buildroot/dl
  && make` → `output/images/GT-BE98_nand_squashfs.pkgtb`. Bump
  `board/gt-be98/RELEASE` (br-00NN monotonic, next = br-0044) and COMMIT
  before the final build (marker carries the git SHA; a dirty tree taints
  it).
- **`board/gt-be98/rootfs-remove.list` is CUMULATIVE** — the transform
  re-unpacks the pristine 0031 blob every build; never reset it to just
  the new slice (rootfs-diff caught this once already).
- Diff proof is MANDATORY pre-flash: extract the previous release's rootfs
  from its archived pkgtb (`output/host/bin/dumpimage -T flat_dt -p 1 -o
  prev.squashfs <pkgtb>`) and run `rootfs-diff.sh prev.squashfs
  output/images/rootfs.squashfs output/host/bin/unsquashfs`; expect ONLY
  the intended entries (directory-inode size jitter in the listing is
  normal squashfs renumbering).
- Git identity `guillaume <guillaume.chaye@zeetim.com>`; trailer
  `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`. Remotes:
  github.com/nebuloss/{gt-be98-buildroot,gt-be98-docs} — pull --rebase
  before push (operator commits to docs remotely).
- Device: ASUS GT-BE98 production AP (sw_mode=3), nets Ramondia/br20,
  Pagoa/br30, DEV-SCEP/br50. SSH `admin@10.0.0.8 -p 2222` (key auth);
  NEW Buildroot dropbear also on :2223 (key-only). Run on-device scripts
  as `/bin/sh script`; `/sbin/sh` is NOT a shell. Host is on VLAN 50
  (routed); after lease churn use `nmap -p 2222 --open 10.0.0.0/24`.
- Host quirks: `rtk` NOT installed (a hook may rewrite `ls` into a broken
  command — use `find`/`stat` instead of bare `ls` locally); zsh eats
  `echo ===foo===` (leading `=` expansion). busybox test binaries must be
  NAMED `busybox` (argv[0] dispatch).

## 2. Current device state (end of session 2026-06-06 ~15:00)

- **Slot 1 = br-0043 (RUNNING, COMMITTED, gate 20/20)**, seq 33,32;
  slot 2 = br-0042 (gate 20/20) fallback. No armed flags,
  reset_reason 0x34, factory MAC 60:cf:84:38:87:b0, zero `20:CF:30` nvram.
- Content: 0031 ASUS rootfs + identity marker + v2 dead-man (S26) +
  breadcrumbs (S27) **+ M4 strip (22 paths: telemetry, networkmap/uamsrv,
  cfg_server/wlc_nt/lldpd, all amas symlinks, bsd/roamast)** + `/usr/br`
  toolbox: dropbear 2025.89 (rail S28, :2223, hostkey /data/br/dropbear),
  busybox 1.37.0 + 401 applet links, openssl 3.6.2 CLI
  (OPENSSLDIR=/usr/br/etc/ssl). All static. Stock binaries untouched.
- **Verify at session start**: cmdline `ubi.block=0,4` (slot 1), committed
  1, valid 1,2; MAC checks above; :2222 and :2223 both answer.

## 3. Safety invariants (absolute)

1. Committed slot always holds a gate-validated image.
2. Trials ONLY via `board/gt-be98/trial/trial-flash.sh --reboot --window
   300 <pkgtb>` (ONCE works, 13/13 lifetime; never `-N` or states 5/7;
   verify state by reading, never exit codes). Auto-disarm: probe SSH from
   ~70 s post-reboot and `touch /tmp/deadman-disarm` on first answer
   (driver pattern in the journal; previous session scripted it).
3. Dead-man flag on **/data** (never /jffs); only the operator removes it:
   PASS → gate → `rm /data/.trial-armed`; FAIL → neutralize (flash
   previous good artifact over the trial slot, `+G`, rm flag). Read
   `/data/boot-breadcrumb.log` after EVERY trial.
4. `/proc/bootstate/active_image` LIES — booted slot = cmdline ubi.block
   (0,4=1, 0,6=2).
5. Shared state sacred: no experimental `nvram commit`; never touch
   loader/U-Boot env. **envrams: kill+firewall stance only. The
   br-0033-style wrapper (= patch-0032 design) is BANNED from the rootfs
   transform pipeline as-is** — hardware evidence (6-slice bisect,
   2026-06-06) shows gated-off envrams ⇒ BSP-MAC nvram poisoning on
   normal boots. Any redesigned gate trial MUST include the MAC slice-gate
   (§0.3) and an nvram backup staged first.
6. Only images reusing the proven 0031 bootfs. Kernel/bootloader from
   source stays DEFERRED.
7. Outage discipline: ≤3 trial cycles/day default (operator may waive —
   2026-06-06 ran 10 cycles on explicit "go ahead"); end every session on
   a validated committed image, no armed flags.
8. Device dark after reboot: suspect lease churn + per-IP firewall first
   (nmap sweep), then wait out dead-man (+300 s) + boot; probe ≥2 h; never
   thrash. Power events boot the committed good slot.

## 4. Proven patterns (use them)

- **Trial cycle** (10/10 clean on 2026-06-06): edit transform inputs →
  bump RELEASE → commit → build → diff proof → archive pkgtb +sha256 to
  `~/be98/artifacts-br/` → trial-flash --reboot → auto-disarm → gate
  (`trial/gate-check.sh --expect-slot N --expect-sha br-00NN+g<sha>`) +
  slice-specific checks → `rm /data/.trial-armed` (init self-commit
  already adopted) → journal + backups (`nvram show`, /jffs tar, ps,
  breadcrumbs → `~/be98/device-backups/<date>-br-00NN/`) → commit+push.
- **De-risk rule for new binaries: live-test from /tmp over SSH BEFORE
  staging** (caught busybox argv0 + openssl OPENSSLDIR defects pre-flash).
- **M5 prefix is `/usr/br`** (NOT /opt/br — /opt is a tmpfs symlink).
  Static builds via toolchain wrapper on PATH
  (`~/be98/buildroot-m1/output/host/bin`); dl cache `~/be98/buildroot/dl/`.
- Slice gates: webui probe = `http://127.0.0.1:8080/` (not
  /Main_Login.asp); usbmuxd lives at `/usr/bin/usbmuxd`; dnsmasq NOT
  expected on this AP.
- Toolchain ceiling gcc 10.3/glibc 2.32 (no GCC-11+ packages; samba4/cmocka
  known-fail — take from ASUS blobs or skip).

## 5. Backlog order

1. Session-start verification (§2) + soak check (:2223 answers, uptime).
2. lighttpd/webui-go admin-path validation (research + live, no flash) →
   then candidate-4 trial(s) under /usr/br with its own gate.
3. dropbear promotion decision per §0.1 (only if soak window satisfied).
4. patch-0032: only per §0.3 / operator updates in the docs repo.
5. wanduck: KEEP until webui-go validation lands (then decide with the
   operator's plan).
6. Final report: shipped / proven vs assumed / incidents / next backlog;
   pending-user-actions list (release uploads rootfs-0031/bootfs-0031).
