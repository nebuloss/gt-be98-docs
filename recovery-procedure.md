# GT-BE98 Firmware Recovery Procedure (go/no-go evidence)

Research date: 2026-06-05. Target: ASUS ROG Rapture GT-BE98 (BCM6813, asuswrt 3006.102.x, src-rt-5.04behnd.4916).

Evidence tags:
- **[V-source]** — verified in the local vendor tree `gt-be98-firmware/vendor/asuswrt-merlin.ng` (paths below are relative to `release/src-rt-5.04behnd.4916/` unless noted). Binary evidence comes from the GPL-shipped prebuilt objects / linked U-Boot (`bootloaders/obj/uboot/u-boot`, `u-boot.map`, `u-boot.dis`, `obj.gt-be98/*.o` — ASUS redacted several .c files and ships .o).
- **[confirmed GT-BE98]** — model-specific (manual, env config, build config).
- **[inferred: X]** — extrapolated from sibling model / generic ASUS behaviour.

---

## 1. Rescue mode (Firmware Restoration)

### Entry sequence [confirmed GT-BE98]

1. Unplug power.
2. Press and **hold the Reset button**, plug power back in while holding.
3. Keep holding until the **power LED blinks slowly** → rescue mode.

Sources:
- ASUS official FAQ (all models incl. BE series): https://www.asus.com/support/faq/1000814/
- GT-BE98 user manual, "Firmware Restoration" (p.125): https://www.manualslib.com/manual/3419222/Asus-Rog-Rapture-Gt-Be98.html?page=125
- [V-source] The GT-BE98 U-Boot is ASUS-modified to implement exactly this: `obj.gt-be98/common/autoboot.o` contains `rescue_btn_pressed`, `"> Enter rescue mode ! active port is %d"`, `turn_cled_rescue` (rescue LED pattern), `asusrescue: %d, delay: %d`. The rescue loop lives in `asus_tasks` (registered every 1000 ms from `board_late_init`, seen in `obj/uboot/u-boot.dis`).

Practical LED note [inferred: RT-AX88U Pro, same generation]: the "slow blink" can look like *solid → off → solid* cycles; the reliable detector is a continuous ping (`ping -t 192.168.1.1` on Windows) — the TTL changes when rescue mode answers (community reports TTL 64 → 100). Source: https://www.snbforums.com/threads/asus-ax88u-pro-router-reset-puts-it-into-rescue-only-shows-power-5ghz-button-no-luck-despite-succesfull-rescue-restoration.90703/ and https://www.snbforums.com/threads/how-to-use-rescue-tool-firmware-restoration-on-asus-router.29434/

### IP addressing in rescue mode [confirmed GT-BE98, V-source]

- Router in rescue mode = **192.168.1.1** (not 192.168.50.1). U-Boot env for this exact board: `ipaddr=192.168.1.1`, `netmask=255.255.255.0`, `boardid=GT-BE98_ICP` — `bootloaders/build/configs/env_NAND_2M_GT-BE98.conf`. The rescue path even force-resets a changed `ipaddr` back to 192.168.1.1 (`"Reset env ipaddr as default"` / `setenv ipaddr 192.168.1.1; saveenv` strings in `autoboot.o`).
- The rescue loop executes `setenv serverip 192.168.1.100` then `tftp xx.bin` [V-source: strings resolved from `asus_tasks` `run_command_list()` args in `u-boot.dis`].
- PC setup: static IP on the 192.168.1.x subnet, mask 255.255.255.0. ASUS FAQ uses **192.168.1.10**; given `serverip=192.168.1.100` [V-source], **192.168.1.100** is the safest choice (it is the address the bootloader's own TFTP transactions target). Connect to a LAN port, single cable, no switch if possible.

### Restoration paths

**(a) ASUS Firmware Restoration tool (Windows, also macOS App Store)** — [confirmed GT-BE98]
Official path; listed in the GT-BE98 manual. Install tool → enter rescue mode → Browse → select stock firmware → Upload. Sources: https://www.asus.com/support/faq/1000814/ , manual p.125 (links above).
[V-source corroboration]: the ASUS rescue handshake is compiled into this U-Boot — `ASUSSPACELINK` magic, `Asus_Rescue:%d`, `RescueAckFlag` in `u-boot-2019.07/net/tftp.o` / linked `u-boot` (ASUS ships these as prebuilt .o; sources redacted). This is the protocol the Restoration tool speaks.

**(b) Mini web rescue page (http://192.168.1.1) — present in binary but NOT auto-started** [V-source]
- Broadcom's U-Boot web-failsafe server **is compiled in**: `CONFIG_BCMBCA_HTTPD=y` in `bootloaders/u-boot-2019.07/configs/bcm96813_defconfig`; the linked u-boot embeds the full "Software update" HTML upload page (`<form method="post" enctype="multipart/form-data"><input type="file" name="firmware">…`), handler chain `http_update_image → check_pkgtb_boardid → flash_upgrade_img_bundle` (`board/broadcom/bcmbca/httpd/bcmbca_net.c`).
- **But** disassembly of `board_sdk_late_init_l` shows `http_poll` is auto-registered **only when the env var `boardid` is undefined** (factory-blank board). On a provisioned GT-BE98 (`boardid=GT-BE98_ICP`) the web server does **not** start at boot or in rescue mode; the rescue loop (`asus_tasks`) only runs `printenv` / `setenv serverip` / `tftp` / `flash_img_upgrade` / `reset` — no `httpd_start`.
- The page **can** be started manually from the U-Boot **serial console**: `sdk httpd_start` (command present, `do_httpd_start` in `sdk_test_commands.c`). So: web rescue = serial-console-assisted option only, not a standalone recovery path. **Plan around the Restoration tool / TFTP, not the web page.**

**(c) TFTP push / fetch** [V-source for mechanism; exact tool interaction inferred]
- The rescue loop's `tftp xx.bin` against `serverip 192.168.1.100` means the bootloader actively tries to **fetch a file literally named `xx.bin` from a TFTP server at 192.168.1.100**, then prints `Ready to upgrade:%d.` and runs `bca_test flash_img_upgrade -s xx.bin` (flash from RAM) followed by `reset` [V-source: `autoboot.o` strings + resolved `run_command_list` args].
- Manual recovery without the ASUS tool therefore: PC at 192.168.1.100/24 running a TFTP **server**, stock `.pkgtb` renamed/served as the requested file, router in rescue mode. (Untested here; classic `tftp -i 192.168.1.1 put` client-push is the documented method for older ASUS models and may also be accepted by the ASUS-modified tftp handler — both ASUSSPACELINK push handling and the comfw model table live in the redacted `tftp.o`.) Generic ASUS TFTP recovery references: https://www.snbforums.com/threads/how-to-use-rescue-tool-firmware-restoration-on-asus-router.29434/ , https://chrishardie.com/2013/02/asus-router-firmware-windows-mac-linux/

Serial console note: U-Boot prompt (`Hit any key to stop autoboot`) is available on UART; from there `sdk flash_img_upgrade <file>` (TFTP fetch + flash), `sdk metadata`, `sdk restoredefault`, `sdk httpd_start` give full manual control [V-source `sdk_test_commands.c`].

---

## 2. What rescue mode accepts

- **Format**: the `.pkgtb` bundle (a FIT/DTB container holding loader, bootfs, rootfs). Both the local build (`build.sh` → `GT-BE98_*.pkgtb`) and ASUS/Merlin releases for this platform use it; the stock webUI upgrade stores uploads as `/tmp/newfirmware.pkgtb` (`src/router/httpd/web.c:15315`) [V-source].
- **Checks applied at rescue/U-Boot flash time** (`flash_upgrade_img_bundle`, `sdk_test_commands.c:2597`) [V-source]:
  1. `fit_all_image_verify()` — FIT structure + **hash integrity** of every sub-image (corrupt/truncated upload rejected).
  2. `check_pkgtb_boardid()` — **ASUS model check**: pkgtb board id must match the router (`GT-BE98`); also a comfw model table in `tftp.o`. Wrong-model stock images are rejected.
  3. `verify_compat_string()` — Broadcom chip/flash/dimension compat (`"rev=a0+;ip=ipv6,ipv4;ddr=ddr4"`, `options_6813_nand.conf.GT-BE98`). Can be bypassed only via console `sdk force 1`.
- **Stock images: accepted — yes.** Rescue-flashing the matching stock `.pkgtb` is the designed recovery path (ASUS FAQ + manual; the entire ASUS rescue machinery exists to do exactly this). [confirmed GT-BE98 by design; community success reports across the AX/BE family]
- **Signature checks**: **no RSA signature gate at rescue level.** `CONFIG_FIT_SIGNATURE=y` is set, but the U-Boot control DTB (`obj/uboot/dts/dt.dtb`) contains **no /signature key nodes**, so verification is hash-only/opportunistic [V-source]. The GPL build signs the FIT with Broadcom **demo keys** (`bcm_cred_dir=targets/keys/demo/GEN3`, `Krot-fld.pem`) — and third-party asuswrt-merlin builds from this same tree boot on retail GT-BE98 Pro units, which demonstrates retail units do not enforce an ASUS-private production signature on the firmware FIT. Residual uncertainty: per-unit OTP secure-boot fusing (GEN3 `SEC_ARCH`) cannot be proven from source alone, but the Merlin-on-retail datapoint makes an enforced private key practically excluded. [inferred: GT-BE98 Pro / Merlin release practice — https://github.com/RMerl/asuswrt-merlin.ng]
- Consequence for go/no-go: **a self-built (modified) pkgtb with valid FIT hashes and correct boardid is also accepted by rescue** — rescue is a model gate, not a signature gate. Recovery to stock is always available via the same path.

---

## 3. A/B slot (dual-image) behaviour — 5.04behnd / BCM6813

Layout [V-source `env_NAND_2M_GT-BE98.conf`]: NAND `2M loader / 254M image (UBI: bootfs1/rootfs1/bootfs2/rootfs2 + metadata) / crashlog`. Factory env `once=sdk metadata 1 1` initialises metadata to *committed=1, valid=1*. `bootcmd=printenv;run once;sdk boot_img`.

### How the bootloader chooses the slot
`get_fit_load_vol_id()` in `bootloaders/u-boot-2019.07/board/broadcom/bcmbca/board_tpl.c` (runs in TPL, every boot) [V-source]:

1. Read image **metadata** (redundant copies, CRC-checked): `committed` (0/1/2), `valid[2]`, `seq[2]`.
2. Only one valid image → boot it.
3. Both valid → boot the **committed** one; if none committed → boot the higher **sequence number**.
4. **Trial boot ("ONCE")**: if the reset reason carries `BCM_BOOT_REASON_ACTIVATE`, boot the **non-committed** image once (`selected_img_idx = 3 - committed`). This is what `bcm_bootstate BOOT_SET_NEW_IMAGE_ONCE` / `sdk activate` arms; a subsequent normal reboot returns to the committed slot unless userspace commits.
5. **Load-failure fallback**: if the selected slot's FIT fails to load/parse (bad flash, corrupt image), the TPL load loop retries with `try_another` and boots the **other valid slot** (`tpl_load_image`, `board_tpl.c:952`) [V-source]. This covers "bricked slot" but not "kernel crashes after load".

### Auto-rollback on boot failure — **largely DISABLED on GT-BE98**
- The crash-loop rollback mechanism exists in the SDK: `check_image_fallback_needed()` triggers fallback when the previous reset was a **watchdog** reset that happened in phase TPL / U-Boot / `LINUX_START` (i.e. Linux never reached steady state); `MAX_BOOT_FAILED_COUNT = 3` retries before staying on the fallback image (`bcm_bootstate.h`, `do_check_fallback`) [V-source].
- **But it is compiled out for this board**: `# CONFIG_BCM_BOOTSTATE_FALLBACK_SUPPORT is not set` in the BCM6813 U-Boot build (`bootloaders/obj/uboot/.config:239`, built from `bcm96813_defconfig` which doesn't enable it) [V-source — GPL build config; retail bootloader assumed identical]. Without it, `get_fit_load_vol_id` ignores boot reason for slot choice and the failed-boot counter logic is absent.
- "What counts as boot failure" (for reference, where the mechanism *is* enabled): a **hardware watchdog reset** before userspace writes the steady-state marker. The marker is written by the Broadcom init script `S25mount-fs` (`router-sysdep.gt-be98/scripts/std/mount-fs.sh` → `echo "steadystate" > /proc/bootstate/reset_reason; echo 0 > /proc/bootstate/boot_failed_count`), launched via `bcm_boot_launcher start` which ASUS `init.c` calls at the very start of boot (`src/router/rc/init.c:25000`) [V-source]. A clean `reboot` sets reason `REBOOT` (no watchdog bit, `bcm_arm64_setup.c`), a kernel panic after steady state sets `PANIC` — neither triggers fallback. A power-cycle (non-SW reset) *clears* the failed-boot counter.

### Userspace slot commands [V-source]
- **Normal upgrade path commits immediately — there is no trial window in stock flow.** WebUI upload → `hnd-write <pkgtb>` (`rc.c:5015`) → `bca_sys_upgrade()` (`src/router/rc/mtd.c:1284`) writes the **inactive** slot then calls `setBootImageState(BOOT_SET_NEW_IMAGE)` (`mtd.c:1246`) = mark valid + **commit** before the first boot of the new image. Same in `bcm_flasher` (`router-sysdep.gt-be98/bcm_flasher/bcm_flasher.c:128`) used by `fwupg_flashing.c`.
- `bcm_bootstate <state>` (`router-sysdep.gt-be98/bcm_bootstate/bcm_bootstate.c`): `1`/`BOOT_SET_NEW_IMAGE`, `2`/`BOOT_SET_OLD_IMAGE`, `3`/`BOOT_SET_NEW_IMAGE_ONCE` (trial), `4`/`BOOT_SET_OLD_IMAGE_ONCE`, `5`–`8` PART1/PART2 (+ONCE), `+N`/`-N` = commit/uncommit partition N. No arg → prints partitions, seq#, commit flags.
- ASUS helpers: `rc bootstate` (check boot policy), `rc syncboot` (`src/router/rc/rc.c:2073`).
- Inspect: `/proc/bootstate/{active_image,boot_failed_count,reset_reason,old_reset_reason,reset_status}` (driver `bcmdrivers/opensource/char/bcm_bootstate/impl1/`).
- U-Boot console: `sdk metadata [committed [valid1,valid2]]` (read/set commit+valid), `sdk activate` (one-shot boot of non-committed slot via ACTIVATE reset reason), `sdk boot_img [1|2]`, `sdk flash_img_upgrade [-i no-commit] <file> [slot]` — note the **`-i`** flag flashes *without* committing, useful for a manual trial workflow.

---

## 4. The gap: boots-fine-but-broken-SSH does NOT roll back — **CONFIRMED**

Three independent reasons, all [V-source]:

1. **Crash-loop rollback is compiled out** of the GT-BE98 bootloader (`CONFIG_BCM_BOOTSTATE_FALLBACK_SUPPORT` not set). Even a kernel that watchdog-resets in a loop will be re-selected forever (only a FIT that fails to *load* falls back to the other slot).
2. Even where the mechanism exists, the "image is good" marker (`steadystate` → `/proc/bootstate/reset_reason`) is written by `S25mount-fs` **immediately after filesystems mount**, long before dropbear/httpd/wireless start. An image that mounts its rootfs is already "good"; broken SSH/web admin is invisible to it.
3. The stock upgrade flow **commits the new image before its first boot** (`BOOT_SET_NEW_IMAGE`, not `_ONCE`). There is no trial boot to fail: the bootloader will keep choosing the new image because it is the committed one, regardless of what userspace does or doesn't bring up.

**Operational consequences for custom-firmware flashing:**
- A custom image with broken admin access (SSH/web) but a booting kernel = **soft-brick with no automatic escape**. Planned escape hatches: (a) rescue mode + stock pkgtb (section 1 — always available), (b) UART serial console (U-Boot `sdk` commands incl. `sdk metadata 1` to re-commit slot 1), (c) flash custom images with `bcm_flasher`/`sdk flash_img_upgrade -i` + `bcm_bootstate BOOT_SET_NEW_IMAGE_ONCE` to get a one-boot trial that reverts on the next power-cycle.
- Recommended pre-flash drill: keep the *known-good stock* image in the other slot (don't flash twice in a row before validating), verify `bcm_bootstate` shows both slots valid, and test rescue-mode entry + ping handshake **before** the first custom flash.

---

## Key sources

| # | Source | Used for |
|---|--------|----------|
| 1 | https://www.asus.com/support/faq/1000814/ | Official rescue-mode entry + PC static IP + Restoration tool procedure |
| 2 | https://www.manualslib.com/manual/3419222/Asus-Rog-Rapture-Gt-Be98.html?page=125 | GT-BE98 manual, Firmware Restoration chapter |
| 3 | https://github.com/RMerl/asuswrt-merlin.ng | Upstream of local vendor tree (release/src-rt-5.04behnd.4916: bootloaders, rc, bcm_flasher, bcm_bootstate); Merlin-boots-on-retail datapoint |
| 4 | https://www.snbforums.com/threads/how-to-use-rescue-tool-firmware-restoration-on-asus-router.29434/ | Community rescue how-to (ping/TTL detection, TFTP alternative) |
| 5 | https://www.snbforums.com/threads/asus-ax88u-pro-router-reset-puts-it-into-rescue-only-shows-power-5ghz-button-no-luck-despite-succesfull-rescue-restoration.90703/ | Sibling-model LED behaviour in rescue mode |
| 6 | Local vendor tree `/home/guillaume/be98/gt-be98-firmware/vendor/asuswrt-merlin.ng` | All [V-source] claims (file:line cited inline) |
