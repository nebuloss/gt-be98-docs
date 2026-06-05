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

1. Confirm which slot is **live** (the one we're SSH'd on) — never overwrite it.
2. Write the image to the **INACTIVE** slot only.
3. Arm **`BOOT_SET_NEW_IMAGE_ONCE`** (one-shot trial; power-cycle = automatic return to the
   current good slot).
4. Reboot → on the new slot verify, in order: **SSH `:2222` reachable** (hard gate) → 4 radios
   up → the 4 user nets (Pagoa/VID30, Ramondia/VID20, DEV-SCEP/VID50, test/VID40) serve clients
   → webui-go applies/reads WiFi config.
5. ONLY after all of step 4: commit the slot (`BOOT_SET_NEW_IMAGE`). Any failure → power-cycle
   reverts to stock slot; worst case → §5 rescue mode with stock pkgtb.

## 7. Flash-readiness checklist (human to confirm)

- [x] Patch set committed (0001–0031) incl. always-on-dropbear failsafe
- [x] Image built, structure-validated, checksummed (NOT flashed)
- [x] SSH-survival proven byte-unchanged; dropbearmulti identical; failsafe present
- [x] Recovery procedure documented; rescue accepts stock image
- [x] Staged inactive-slot + one-shot-trial plan written (§6)
- [ ] **webui-go owns WiFi apply + status at runtime** — cfg_server is gated off in this image:
  the stock GUI apply path + status JSON die with it. **Do not flash before the webui-go agent
  confirms full ownership on the live AP.** ← the one open gate
- [ ] Human decision: flash yes/no, which slot, when (coordinate with the live webui-go agent —
  a reboot destroys its session state)

— orchestrator, 2026-06-05
