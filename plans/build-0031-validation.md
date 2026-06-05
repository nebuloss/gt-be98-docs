# Build 0031 validation — patched (0001–0031) vs baseline (0001–0027)

Date: 2026-06-05. Local static analysis only (strings / objdump / dumpimage / squashfs
inspection). No flash, no device contact, no source modification.

- Baseline: `baseline-0027/` (built 2026-06-04, patches 0001–0027). `sha256sum -c SHA256SUMS` → all OK [V].
- Patched: `vendor/asuswrt-merlin.ng/release/src-rt-5.04behnd.4916/targets/96813GW/` (built 2026-06-05 14:35 UTC, patches 0001–0031).
- Toolchain objdump/nm/objcopy: brcm-arm-hnd crosstools gcc-10.3 binutils-2.36.1.

## VERDICT: **FAIL** (checklist C — unexpected NFS config drift; everything SSH/patch-related PASSES)

The four new patches (0028–0031) are correctly and minimally present in the binary.
The failure is NOT in the patches: today's build additionally compiled in the **NFS
server** (RTCONFIG_NFS=y), which the baseline build did not have. This is the known
"stale busybox autoconf.h spuriously enables NFS" issue already documented in
`gt-be98-firmware/tools/verify-artifact.sh` (l.199–205) and `docs/troubleshooting.md`
(l.141). The artifact is therefore not the minimal-delta image vs baseline.
Options: (a) clean rebuild with NFS off → re-validate (expected: only patch-touched
functions differ), or (b) explicitly accept the NFS delta (it is runtime-inert by
default, see C3). Decision deferred to go/no-go owner.

## A. Gate code present — PASS
`strings fs.install/sbin/rc` contains exactly once each: `cfgmnt_enable`,
`wlc_nt_enable`, `amas_lanctrl_enable`, `amas_lldpd_enable`, `amas_portstatus_enable`,
`bsd_enable`, `roamast_enable` [V].

## B. Failsafe code present — PASS
nm: `sshd_check` exists in patched unstripped rc (0xa2270 T), absent from baseline [V].
Disassembly [V]:
- patched `start_sshd` contains `movw r3, #2222` twice (failsafe port + secondary
  `-p 2222` listener), one conditional (`movweq`) — baseline `start_sshd` contains no
  2222 immediate anywhere; function grew (~116 B more literal pool), consistent with
  the early-`return 0` on `sshd_enable==0` being replaced by the failsafe branch.
- `sshd_check` body: `bl <pids@plt>` → if 0 → tail-call `b <start_sshd>` [V].
- `watchdog()` call-graph diff vs baseline: exactly one added call, `bl <sshd_check>` [V].
- `strings fs.install/sbin/rc` contains standalone `2222` [V].

## C. Blast-radius per-function disassembly diff — **FAIL (explained: NFS drift, not patches)**
Method: objdump -d both unstripped rc, split per symbol (3546 base / 3551 patched),
normalize (strip addresses/encodings, mask literal-pool `.word`, raw branch-target
addresses); second pass additionally masks pc-relative pool offsets, `<sym+0xoff>`
annotations and trailing immediates to isolate structural changes; call-graph (`bl`)
diff per function as ground truth.

### C1. Expected changes (patches 0028–0031) — all present, nothing missing [V]
services.c: `start_cfgsync`, `start_wlc_nt`, `start_amas_lanctrl`, `start_amas_lldpd`,
`start_amas_portstatus`, `start_bsd`, `start_roamast`.
watchdog.c: `cfgsync_check` (0028 gate), `watchdog` (+1 call `bl <sshd_check>`),
new symbol `sshd_check` (0031). ssh.c: `start_sshd` (0031).

### C2. UNCHANGED confirmation (byte-identical normalized disassembly) [V]
`start_lan`, `stop_lan`, `start_dnsmasq`, `start_eapd`, `start_nas`, `start_wan`,
`restart_wireless`, `hotplug_net`, `start_hostapd`, `start_wlceventd`,
`start_mcpd_proxy` — all identical baseline↔patched.

### C3. UNEXPECTED structural changes — NFS server compiled in (the FAIL)
New symbols in patched rc only: `start_nfsd`, `start_nfsd.part.0`, `stop_nfsd`,
`creat@plt` (creat() used by start_nfsd for /var/lib/nfs/etab|xtab|rmtab) [V].
Call-graph changes [V]: `start_nas_services` +`bl <start_nfsd>`;
`stop_nas_services` +`bl <stop_nfsd>`; `init_nvram` 105→106 calls to
`add_rc_support` (init.c:23046 `add_rc_support("nfsd")` under RTCONFIG_NFS).
Image level [V]: `/usr/sbin/nfsd` and `/usr/sbin/exportfs` present inside the patched
pkgtb rootfs, ABSENT from the baseline pkgtb rootfs.
Root cause: router `.config` of today's build has `RTCONFIG_NFS=y` (line 438);
generated `config_gt-be98`/`config_current` also =y, while `config_base` has it unset
and the baseline clean build shipped without NFS. Matches the documented spurious-NFS
issue (verify-artifact.sh comment, troubleshooting.md).
Runtime impact assessment: `start_nfsd` (usb.c:5928) begins
`if (nvram_match("nfsd_enable", "0")) return;` and defaults.c:5059 sets
`nfsd_enable=0` → inert at runtime by default [V]. It is only reachable via
`start_nas_services` (USB/NAS path), not via LAN/WiFi/SSH paths. Still a
config-provenance failure for a minimal-delta release.

### C4. Remaining diffs = relocation/codegen noise (no behavior change) [V]
- ~1040 `*@plt` stubs differ only in GOT-offset immediates (one new dynamic symbol
  `creat` shifts the GOT/PLT layout).
- 22 functions differ only in rodata-anchor constants / pc-relative pool offsets /
  register allocation, with EMPTY `bl` call-graph diff each [V]:
  add_usb_host_modules, gen_chilli_ipup_script, handle_notifications,
  setup_nc_event_conf, start_CP, start_amas_misc, start_auto46det, start_chilli,
  start_cloudsync, start_dms, start_ftpd, start_lpd, start_mt_daapd,
  start_nat_rules.part.0, start_usb, start_webdav, stop_ddns, stop_nat_rules,
  stop_samba, stop_usb, vpclose, write_ftpd_conf.
  (Cause: .rodata layout shift in services.c/usb.c/init.c TUs from the patch hunks and
  the RTCONFIG_NFS recompile.)

## D. dropbearmulti unchanged — PASS
sha256 identical: `739c02d3d4bf6cd2b08e30cfce3874e6dba4d87254f8306f546b22b16a51a6b3`
for baseline `dropbearmulti.baseline`, patched `fs.install/usr/bin/dropbearmulti`, AND
`/usr/bin/dropbearmulti` extracted from inside the patched pkgtb squashfs [V].

## E. Rootfs SSH inventory — PASS
Inside patched pkgtb rootfs [V]: `/usr/bin/dropbearmulti` (file) + symlinks
`/usr/sbin/dropbear→../bin/dropbearmulti`, `/usr/bin/{dropbearkey,ssh,scp,dbclient}→dropbearmulti`.
Host keys: NONE shipped in the image (find over fs.install: 0 matches) [V]. Keys are
generated at runtime by `check_host_keys()` (rc/ssh.c:13–37): persistent in
`/jffs/.ssh/dropbear_{rsa,ecdsa,ed25519}_host_key`, symlinked into `/etc/dropbear/`;
if JFFS unwritable, temporary RAM keys in `/etc/dropbear/` [V]. Firmware defaults
(defaults.c, non-DEMOUI): `sshd_enable=0`, `sshd_port=22`, `sshd_pass=1`; the live
device nvram is `sshd_enable=2, sshd_port=2222` (gt-be98-docs/behaviour.md l.318) —
the 0031 failsafe hardcodes :2222 so it coincides with the fleet port; with
sshd_port=2222 configured, behavior is identical to today plus watchdog respawn [V].

## F. KEEP→GATE call independence — PASS
In patched rc disassembly [V]: `start_eapd`, `start_hostapd`, `start_dnsmasq`,
`start_mcpd_proxy`, `start_wlceventd`, `hotplug_net`, `start_wan`, `start_lan` contain
zero `bl` into any gated function. Full-binary callers of the 7 gated functions:
only `start_services`, `handle_notifications`, `check_services`, `lan_up`,
`restart_wireless`, `main` — all pre-existing vendor call sites (same in baseline,
those callers' call-graphs unchanged); the gate is inside the callee, which now
returns immediately when its flag is 0. No new KEEP→GATE edge introduced [V].

## G. pkgtb structure — PASS
`dumpimage -l` both FITs [V]: identical structure — description `GT-BE98`,
Image 0 `bootfs_6813_a0+`, Image 1 `nand_squashfs` (rootfs), default config
`conf_6813_a0+_nand_squashfs`; loader pkgtb: 3 images (loader/bootfs/rootfs), same
names. Diffs limited to timestamps, rootfs size 63 897 600 → 64 036 864 B (+0.22%,
NFS binaries + rc delta) and hashes. Whole-file sizes: 77 226 696 → 77 365 960
(+0.18%); loader 79 324 084 → 79 463 348 (+0.18%) — well within 1%.
bootfs same size (13 328 136 B), 337/13.3M bytes differ, all in u-boot version
timestamp strings ("06/04/2026-10:38" → "06/05/2026-14:32") and the recomputed FIT
hash nodes [V] — pure build-timestamp noise, kernel content otherwise identical.
Chain of custody [V]: rootfs embedded in pkgtb is byte-identical to `rootfs.img`;
`/sbin/rc` extracted from inside the pkgtb squashfs sha256-matches
`fs.install/sbin/rc`, whose `.text` section is byte-identical (objcopy+cmp) to the
analyzed unstripped `src/router/rc/rc`.

## H. Checksums (sha256) [V]
Patched:
- `GT-BE98_3006_102.6_0_nand_squashfs.pkgtb` (77 365 960 B):
  `a7dcd0c14669eb363be775fc208f1f73098226723e420a3e3408095b1e98fa01`
- `GT-BE98_3006_102.6_0_nand_squashfs_loader.pkgtb` (79 463 348 B):
  `d563b027474ff94a5d84bb7b799e23babeafe4f2c303fac619c8546de4434e08`
- `fs.install/sbin/rc` (== /sbin/rc inside pkgtb):
  `98fb44fe03569bf6b9381b9f92146a9a00011dd8c572e6187e06e2ae8ee951ca`
Baseline (SHA256SUMS, re-verified OK):
- pkgtb `796ada9eecb0a59dd254401ce6bbc89055bf352d566291510124c4d16222661a`
- loader `0fac693eb8842d6f1f31665f5a824269a5c70d7cd9d44c00bc068a1359abce17`
- rc.unstripped `c44110bc0d719db705e22f1cfd3433a71b20a6583570e74f7b6b47193462eb7e`
- dropbearmulti `739c02d3d4bf6cd2b08e30cfce3874e6dba4d87254f8306f546b22b16a51a6b3`

## Recommendation
SSH-survival engineering (0028–0031) fully validated in the binary. Do NOT flash this
exact artifact as the "minimal-delta" candidate: rebuild clean (NFS off — wipe
`busybox/include/autoconf.h` / use clean clone as per troubleshooting.md), re-run this
validation (expected result: C goes PASS with only the C1 list + @plt/rodata noise),
then flash. Alternatively accept the NFS delta consciously (inert by default,
nfsd_enable=0) and document it in the go/no-go.

## Addendum — checklist C root-cause (orchestrator, 2026-06-05)

The "unexpected" NFS delta is **explained and accepted**, flipping the verdict to
**FLASH-CANDIDATE PASS (with documented delta)**:

- The Jun-4 **baseline was the anomaly**: its own build log
  (`logs/build_20260604_103450.log`) shows `NFS=y` in the make flag echo — NFS is part of
  the GT-BE98 profile (stock ASUS config) — yet the clean-clone first build silently
  skipped nfs-utils. Commit `700eefe` ("gate nfsd/exportfs verify on RTCONFIG_NFS") was a
  workaround for exactly that. `[V]`
- Today's incremental rebuild regenerated `router/.config` (mtime Jun 5 14:31) from the
  profile, restoring `RTCONFIG_NFS=y`, and nfs-utils built. The patched image is therefore
  **closer to stock** than the baseline w.r.t. NFS. `[V]`
- Runtime-inert: `defaults.c` ships `nfsd_enable=0`; `start_nfsd()` early-returns. No
  service or port is opened by default. `[V]` (validation §C)
- Note: the comment in `tools/verify-artifact.sh:199` ("config_gt-be98 has RTCONFIG_NFS
  off by default") is **wrong** — the profile has NFS=y; the real story is the
  clean-clone-misses-nfs-utils build bug. Worth a future comment fix.
- All SSH-survival checks (D/E + start_lan/dnsmasq/eapd/hostapd/wlceventd/mcpd/wan/
  restart_wireless/hotplug_net byte-unchanged) hold regardless. `[V]`
