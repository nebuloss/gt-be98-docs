---
name: next-phase-firmware-re
description: Project direction — next phase is firmware RE/rebuild to patch MAINFH-forcing at the source
metadata: 
  node_type: memory
  type: project
  originSessionId: e141d2d8-83b8-4b66-9faa-d978856115a6
---

As of 2026-06-02, the GT-BE98 webui project's **next phase is reverse engineering + firmware rebuild**: the user has the firmware sources to build firmware.

**Why:** This session proved MAINFH (MyPrivateNetwork = `apm2` profile) is *mandatory* — `/sbin/rc` unconditionally regenerates `bss=wl3.1 / ssid=MyPrivateNetwork` into `/tmp/wl3_hapd.conf` regardless of `apm2_enable=0` (nvram + common.json) or `sdn_rl` MAINFH disable. (NB: `mtlancfg` is NOT a binary — it's only an `add_rc_support` capability flag set at `rc/init.c:23767`; the real config-gen is rc + the closed amas_apg_shared object below.) The current stable workaround (`v1.0.0`) only *hides + unbridges* it via watchdogs (`ssid-suppressor`, `bridge-enforcer`). Building firmware lets us patch the root and retire the watchdog hacks.

**Open/closed boundary (VERIFIED 2026-06-02 via toolchain nm + strings on `gt-be98-firmware` vendor tree):**
- The `/tmp/wlX_hapd.conf` writer is **closed**: `release/src/router/rc/prebuild/GT-BE98/hostapd_config_be.o` (no `.c`). It is a *dumb consumer* — reads only `lanX_ifnames` + per-vif `wlX.Y_*` nvram; contains NO apm/apg/sdn/MAINFH logic. Not the lever.
- The apm/apg/sdn → `wlX.Y` ifname mapping, **including MAINFH/MAINBH**, lives in **closed** `release/src/router/shared/prebuild/GT-BE98/amas_apg_shared.o` (source `amas_apg_shared.c` absent → cannot edit C). Its strings confirm: `MAINFH`,`MAINBH`,`ap%s%d_ssid`,`ap%s%d_dut_list`,`apg_%s_fh_wlifnames`,`wl%d.%d`,`sdn_rl`. The key exported fn is **`get_fh_if_prefix_by_unit(unit,...)`** — returns the fronthaul vif prefix for a radio.
- Makefile override pattern exists (`shared/Makefile:230 OBJS += $(if $(wildcard amas_apg_shared.c),amas_apg_shared.o,prebuild/amas_apg_shared.o)`) — dropping a local `amas_apg_shared.c` would compile from source, but we have no source to patch.
- `MyPrivateNetwork` literal is **nowhere in the firmware tree** (not source, not binaries) → it's a runtime/user nvram value (`apm2_ssid`/`wl3.1_ssid`), so it can't be removed by editing a firmware constant.

**The patchable lever = the OPEN callers of `get_fh_if_prefix_by_unit`** (all gated `if (w_Setting && !repeater_mode() && !mediabridge_mode() && get_fh_if_prefix_by_unit(...))` → use fronthaul vif as the "main" SSID iface; else use plain `wlX_`):
- `rc/services.c:3567`, `rc/services.c:3681`
- `rc/init.c:22674`
- `rc/sysdeps/init-broadcom.c:9211`
- `rc/sysdeps/wps-broadcom.c:392`
- `httpd/web.c:36430`
- Candidate fix: force these to the `else`/plain-`wlX_` branch (e.g. make `get_fh_if_prefix_by_unit` effectively return NULL via a wrapper, or guard each call) to stop MAINFH being treated as the primary fronthaul. RISK: this is the firmware's normal SDN/Guest-Pro main-SSID + AiMesh fronthaul mechanism — disabling globally may break legit primary wifi/mesh. Must understand fh-branch vs else-branch behavior before patching.

Build is known-good (rebuild after patch is viable). See [[docs/sdn_investigation.md §10]] in the repo for the runtime forensic record.

**LIVE-VERIFIED on the router (2026-06-03, phases 0–2, SSH `admin@10.0.0.8:2222`):**
- **Source == running build**: live `buildinfo` = `root@ad42d5e`, matching vendor `UPSTREAM` ref `ad42d5e81a53…`. buildno 102.6, extendno `1-gnuton1`. → anything we compile matches the live firmware exactly.
- **Live MAINFH state**: `apm2_ssid=MyPrivateNetwork`, `apm2_enable=1`, `apm2_dut_list=<*>1>`; `sdn_rl` idx2=MAINFH(en=1,apg2), idx1=MAINBH, idx3/4=Customized. So MyPrivateNetwork SSID **is** runtime nvram (apm2_ssid), not a firmware constant.
- **Real user nets**: NetA (Customized/br20, wl0.1+wl2.1 = 5G+6G), NetB (Customized/br30, wl3.2 = 2.4G), MLO primaries on br0. MAINFH=wl3.1 (2.4G) is the unwanted one.
- **`lan_ifnames` persistently contains `wl3.1`** (`eth0..3 wl0 wl1 wl2 wl3 wl3.1 wl3.4`) → drives br0 membership + the `bss=wl3.1 ssid=MyPrivateNetwork` block in `/tmp/wl3_hapd.conf`. **This is the concrete patch surface.**
- **MAINFH regen trigger = `restart_wireless`**: rc rebuilds br0 from lan_ifnames → wl3.1 recreated **closed=0 + bridged into br0** (raw forced state); webui watchdogs re-apply `closed=1`+`delif` within ~20s. `service-event` hook relaunches the watchdogs on every `restart_wireless`.
- **Watchdogs are the SOLE suppressor**: with both killed by PID, wl3.1 stays `closed=0`+bridged indefinitely — no firmware actor re-hides it. → patching MAINFH at source retires both watchdogs.
- **Daemon disable map (verified)**: nvram-gated (NO rebuild) = `roamast` (`roamast_disable=1`, live-tested: stays dead across watchdog cycles), `acsd` (`acs_disable=1`, already set on this unit), `wanduck` (`no_need_to_start_wanduck()`). Force-respawned by `watchdog.c` with NO nvram gate (need source removal or watchdog patch) = `networkmap` (7995), `infosvr` (11304). 
- All live nvram sets were runtime-only (uncommitted); router rebooted to restore — confirmed clean (watchdogs+socat back, wl3.1 closed=1/unbridged).
