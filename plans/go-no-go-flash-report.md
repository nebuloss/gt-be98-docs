# GO/NO-GO — custom GT-BE98 image (stock-services retired) — flash decision for the human

> Status 2026-06-05: **flash-ready candidate built + validated. NOT flashed.** The flash is a
> human decision; this report is the hand-off. Orchestrator recommendation: **GO, conditional**
> on the webui-go runtime dependency below and the staged inactive-slot procedure.

## 1. The artifact

| | |
|---|---|
| Image | `gt-be98-firmware/artifacts-0031/GT-BE98_3006_102.6_0_nand_squashfs.pkgtb` (74M) |
| sha256 | `a7dcd0c14669eb363be775fc208f1f73098226723e420a3e3408095b1e98fa01` |
| Loader variant | `…_loader.pkgtb` (76M), sha256 `d563b027474ff94a5d84bb7b799e23babeafe4f2c303fac619c8546de4434e08` |
| Built from | merlin behnd 5.04 vendor HEAD + patches **0001–0031**, branch `fix-build-clean-clone`, build exit 0 (3m52s, 2026-06-05 14:35) |
| Baseline kept | `gt-be98-firmware/baseline-0027/` (Jun-4 build, 0001–0027) + SHA256SUMS — for diffing/rollback reference |

## 2. What the image changes vs stock (all reversible per-flag, no nvram default touched)

Gated **off by default** (re-enable: `nvram set <flag>=1; nvram commit; reboot`):

| Patch | Daemons | Flag(s) |
|---|---|---|
| 0024 | infosvr (UDP 9999) | `gtbe98_infosvr` model |
| 0026 | envrams (TCP 5152) | (0026 flag) |
| 0027 | awsiot, networkmap, asd, conn_diag (+`amas_ssd_cd` transitively), mastiff | `gtbe98_*` flags |
| 0028 | **cfg_server** (AiMesh config master) | `cfgmnt_enable` |
| 0029 | wlc_nt, amas_lanctrl, amas_lldpd/lldpd, amas_portstatus | `<daemon>_enable` each |
| 0030 | bsd, roamast (already off in stock; made robust) | `bsd_enable`, `roamast_enable` |
| **0031** | **dropbear FAILSAFE — always-ON** (inverse of the others) | none — cannot be disabled by nvram |

KEEP, untouched: `eapd`, 4×`hostapd`, `wlceventd`, `mcpd`, `dnsmasq`, `dropbear`, `wl`/`dhd`
driver, `rc` (WiFi bring-up + slot allocation). Disposition evidence: `plans/stock-services-disposition.md` `[V]`.

## 3. Validation evidence (full detail: `plans/build-0031-validation.md`, commits 29c0d95+51802f0)

- **Gate code in the built binary** `[V]`: all 7 new flags present in `fs.install/sbin/rc` strings.
- **SSH-SURVIVAL PROOF** `[V]`: per-function disassembly diff baseline-rc vs patched-rc —
  `start_lan`, bridge/LAN bring-up, `start_dnsmasq`, `start_eapd`, hostapd conf-gen,
  `wlceventd`, `mcpd`, `start_wan`, `restart_wireless`, `hotplug_net` **byte-unchanged**.
  Changed functions are exactly the patch targets (gated `start_*`, `start_sshd`, `watchdog`,
  new `sshd_check`) + codegen noise. `dropbearmulti` **sha256-identical** to baseline, in
  staging AND inside the pkgtb squashfs. Host keys: generated at first boot into `/jffs/.ssh`
  (stock behavior, unchanged).
- **No KEEP→GATE dependency in the built binary** `[V]`: zero call paths from any KEEP daemon
  start path into a gated function.
- **pkgtb structure** `[V]`: identical FIT layout vs baseline, sizes +0.18%, bootfs delta =
  u-boot timestamps only, metadata intact; `tools/verify-artifact.sh` all-OK.
- **One accepted delta**: NFS userland (nfsd/exportfs) present (absent in Jun-4 baseline).
  Root-caused: NFS=y is the stock GT-BE98 profile; the *baseline* was anomalous (clean-clone
  nfs-utils build skip). Runtime-inert: `nfsd_enable=0` default, `start_nfsd` early-returns.

## 4. The dropbear failsafe (0031) — brick insurance (`plans/patch-0031-dropbear-failsafe.md`)

- `start_sshd()` no longer early-returns when `sshd_enable=0` — it starts dropbear in failsafe
  mode with **literal port 2222** (never reads `sshd_port`); with sane normal config it also
  guarantees a second `-p 2222` listener. No nvram state can produce "no SSH".
- NEW `sshd_check()` in the watchdog: stock had **zero** dropbear respawn — now a dead dropbear
  is restarted within one watchdog period.
- Limits: guarantees a listener, not credentials (nvram wipe → factory login); a per-connection
  child can mask a dead listener until the session closes.

## 5. Recovery story (researched + documented: `recovery-procedure.md`, commit 820b416)

- **Rescue mode** [confirmed, ASUS FAQ + U-Boot strings `[V-source]`]: hold **Reset while
  plugging in power** until the power LED blinks slowly → router at `192.168.1.1`, pulls
  firmware via TFTP (`serverip 192.168.1.100`) / ASUS Firmware Restoration tool. Rescue accepts
  **stock pkgtb** (FIT hash + boardid checks only, no RSA gate) — stock restore always possible.
- **⚠ A/B auto-rollback is COMPILED OUT on BCM6813** (`CONFIG_BCM_BOOTSTATE_FALLBACK_SUPPORT`
  unset): the bootloader falls back only if the FIT fails to *load*. A kernel-panic loop does
  NOT auto-revert, and a **boots-but-SSH-dead image never rolls back** (steadystate marker is
  written before services start). This is exactly why §3's byte-unchanged proof + §4's failsafe
  + the staged plan below are mandatory.
- One-shot trial boot exists: `bcm_bootstate BOOT_SET_NEW_IMAGE_ONCE` (or
  `sdk flash_img_upgrade -i`) boots the new slot **once** and reverts to the committed slot on
  the next power cycle — use it.

## 6. Staged-flash plan (MANDATORY procedure when the human says go)

0. Pre-flight (per §8): `nvram get jffs2_scripts` == 1 (webui-go boot persistence rides
   `/jffs/scripts/*`; nvram is shared across slots so it survives the flash), and arm a
   `push.sh`-style deadman for the trial boot (webui-go agent's request — lab mgmt path is
   fragile around AP disruptions). Pick a window when `/tmp/webui-applying` is absent and no
   flash upload is running.
1. Confirm which slot is **live** (the one we're SSH'd on) — never overwrite it.
2. Write the image to the **INACTIVE** slot only.
3. Arm **`BOOT_SET_NEW_IMAGE_ONCE`** (one-shot trial; power-cycle = automatic return to the
   current good slot).
4. Reboot → on the new slot verify, in order: **SSH `:2222` reachable** (hard gate) → 4 radios
   up → the 4 user nets (Ramondia/VID20, Pagoa/VID30, DEV-SCEP/VID50, test/VID20 — per §8 live
   correction) serve clients
   → webui-go applies/reads WiFi config.
5. ONLY after all of step 4: commit the slot (`BOOT_SET_NEW_IMAGE`). Any failure → power-cycle
   reverts to stock slot; worst case → §5 rescue mode with stock pkgtb.

## 7. Flash-readiness checklist (human to confirm)

- [x] Patch set committed (0001–0031) incl. always-on-dropbear failsafe
- [x] Image built, structure-validated, checksummed (NOT flashed)
- [x] SSH-survival proven byte-unchanged; dropbearmulti identical; failsafe present
- [x] Recovery procedure documented; rescue accepts stock image
- [x] Staged inactive-slot + one-shot-trial plan written (§6)
- [x] **webui-go owns WiFi apply + status at runtime** — confirmed live with cfg_server
  functionally absent, 2026-06-05 → §8
- [ ] Human decision: flash yes/no, which slot, when (coordinate with the live webui-go agent —
  a reboot destroys its session state)

— orchestrator, 2026-06-05

## 8. webui-go runtime confirmation — 6/6 [V] (live AP, 2026-06-05, webui-go agent)

Method note: on the **stock** firmware cfg_server cannot be kept killed — the watchdog
churns `notify_rc start_cfgsync` every ~31 s and after ~15 failed cycles rc escalates to a
**full reboot** (`rc_service: Rebooting...` observed 17:30:45; the start/kill-9 churn also
broke the br0 mgmt path minutes earlier). All "absent" tests below therefore ran with
cfg_server **SIGSTOPped** (state `T`, pid alive → watchdog quiet, daemon functionally dead;
verified frozen across the whole window). This failure mode is stock-only: the gated image
never starts cfg_server and its watchdog check early-returns.

1. **WiFi apply ownership [V]** — full cycle with cfg_server frozen: create
   (`save_network` psk2/VID70/wl3 → `wl3.7` + own hostapd + `br70` with `eth0-3.70` trunk,
   beaconing, `txbcnfrm` climbing) → fast SSID edit (`hostapd_cli`, hostapd pid unchanged,
   zero outage) → structural PSK+VLAN edit (only `wl3.7` destroyed/recreated into `br30`;
   the sibling net's hostapd pid/starttime untouched) → delete (vif, hostapd, conf, bridge
   membership all cleaned). **No rc involvement at all** — the apply path is
   `wl` + per-BSS hostapd + `brctl` (`internal/wifi`); `sync_apgx`/`restart_wireless`
   survive only inside the already-executed one-shot SDN→direct migration.
2. **Status ownership [V]** — status is read from `wl`/`hostapd_cli`/`iw`/`/proc` directly
   (not netctl, not any cfg_server JSON). With cfg_server dead: `get_radios` = 4 radios
   correct, `list_networks` = the 4 user nets, `list_clients` cross-checked against
   `wl assoclist` on all 13 BSSes. Note `/tmp/wlX_hapd.conf` (read for stock-BSS
   enumeration) is produced by **rc's** hostapd generator, which the image keeps.
3. **No other gated-daemon dependency [V]** — code audit: zero consumption of
   wlc_nt/amas_*/lldpd/conn_diag/bsd/roamast sockets/files/events. Only
   mtlancfg-produced file referenced is `apg_ifnames_used.json` (absent ⇒ graceful
   `false`, correct post-migration).
4. **Boot persistence [V]** — everything in `/jffs` (`/jffs/webui/*` +
   `/jffs/scripts/{services-start,service-event,firewall-start}`). Proven on two
   unplanned reboots the same day: webui auto-started and `reconcileDirect` rebuilt all
   nets + portals + captive + builtin RADIUS with zero operator action — including a net
   created seconds before the reboot. Init assumes no stock service (`killall …
   2>/dev/null` + nvram sets only). Requirement: the image keeps jffs user-scripts enabled.
5. **Reboot state safety [V]** — lost by design: in-memory sessions (re-login), in-memory
   event log, runtime vifs (reconciled at boot, ~90 s). SQLite persists on /jffs; the
   direct path writes no nvram (channel changes commit immediately). Safe window: whenever
   `/tmp/webui-applying` is absent and no flash upload is running.
6. **Clean degradation [V]** — webui at 0.0 % CPU with cfg_server gone; event log shows no
   retries/polls/spam and no cfg_server reference anywhere in the stack.

§6 step-4 correction from live data: the `test` net is **VID 20** (not VID 40); current
nets = Ramondia/VID20, Pagoa/VID30, DEV-SCEP/VID50, test/VID20.

Non-blocking follow-ups: one-shot supervisor relaunch race after a structural reapply
(stale watcher fires once, `ctrl_iface exists`, no loop — cosmetic); stale
"cfg_server-applies" header comment in `scripts/services-start`. For the trial boot, arm a
`push.sh`-style deadman: the lab mgmt path is fragile around AP disruptions, and the
trial-slot commit criteria in §6 already ride SSH `:2222`.

— webui-go agent, 2026-06-05

## 9. FLASH EXECUTED — 2026-06-05 ~18:00 (orchestrator, human GO received)

§6 procedure followed; custom 0031 image (`a7dcd0c1…fa01`) now **live and committed, slot 1**.

- Pre-flight `[V]`: jffs2_scripts=1, no apply marker, active=slot2, both slots valid, 1.2G free.
- Transfer `[V]`: ssh-cat (no sftp-server on stock); on-device sha256 == build sha256.
- Deadman: `/jffs/scripts/flash-trial-deadman` (600s, trial-slot-guarded) + services-start hook;
  installed → consumed → cleaned up after verification. webui-go's services-start restored.
- `hnd-write` wrote slot 1 (seq 19→21, exit 99 = normal "reboot expected"), auto-committed →
  flipped back (`bcm_bootstate 2`) → armed trial (`bcm_bootstate 3`, Reboot Partition First,
  committed 2) → reboot 17:58.
- **SSH answered at T+~70s on the trial slot** `[V]` — Booted Partition First, deadman disarmed.
- Verification on slot 1 `[V]`: 7/7 gate flags in /sbin/rc; cfg_server/wlc_nt/amas_*/lldpd/bsd/
  roamast/conn_diag/infosvr all absent; :2222 listening; 4 radios up; 4 bridges; **all 4 user
  nets beaconing** (Ramondia, DEV-SCEP, Pagoa, test; wl3.1 empty per 0025); webui-go up :8080
  with a live successful login during verification.
- Note: ASUS init **self-commits** a successfully-booted ONCE-trial (observed committed 2→1
  without operator action) — the §6 "commit" step is automatic on this firmware.
- Residual: `envrams` runs despite 0026 (started outside rc — Broadcom launcher path; webui
  killall + firewall :5152 DROP cover it). Follow-up: fix 0026 at the real start site.
- Rollback remains available: stock in slot 2 (valid, seq 20) — `bcm_bootstate 2` + reboot.

**Capstone complete.** — orchestrator, 2026-06-05
