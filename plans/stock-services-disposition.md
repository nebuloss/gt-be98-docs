# Stock-service disposition — standalone-AP daemon map + gate patches (Stage 1)

> Per-daemon verdict (**KEEP** load-bearing vs **GATE** dead weight) for every ASUS/AiMesh
> stock daemon on this **standalone AP** (`sw_mode=3`, `re_mode=0`, `cfg_master=1`,
> `amas_bdl=` empty, no mesh). Method = the cfg_server template
> ([patch-0028-retire-cfg_server.md](patch-0028-retire-cfg_server.md), [cfg_server_re.md](../cfg_server_re.md) §6):
> **static** (who `start_*`s it in `rc/services.c`, who respawns it in `rc/watchdog.c`, its
> gates/deps) + **live dead-man-guarded kill-test** (`killall <d>`; observe WiFi/clients/
> bridges/SSH/core daemons within the watchdog window; restore; verify clean).
> `[V]` = verified live on `10.0.0.8` 2026-06-05. No firmware build, no flash — RE + patch authoring only.

## 1. Live baseline (standalone AP, stock fw running)

Running stock daemons of interest (other agents were live; kill-tests are daemon-only, non-overlapping):
`wlc_nt`, `amas_lanctrl`, `amas_ssd_cd`, `amas_portstatus`, `conn_diag`, `lldpd`×2 (privsep),
`cfg_server`. WiFi core: `eapd`, `hostapd`×4, `wlceventd`, `mcpd`. **Not running** (already off
in stock): `bsd` (`smart_connect_x=0`), `roamast` (`roamast_disable=1`), the `re_mode==1`-only
amas crew (`amas_ssd`/`status`/`misc`/`bhctrl`/`wlcconnect`).

Baseline: 4 radios `isup=1`, `br0` 6 wl-members / `br20` 7 / `br30` 5 (4 user VLANs intact),
`cfg_server`/`eapd`/4×`hostapd` up. Restore execs: `wlc_nt`,`lldpd` are real binaries in
`/usr/sbin`; `amas_lanctrl`/`amas_portstatus`/`amas_ssd_cd`/`conn_diag` are **`/sbin/rc`
multicall symlinks** (restore by re-running the symlink); `lldpd` restored via `/tmp/run_lldpd.sh`.

## 2. Per-daemon verdict

| Daemon | Starter (`services.c`) | Watchdog respawn | Live kill-test result | Verdict |
|---|---|---|---|---|
| **wlc_nt** | `start_wlc_nt` (≈4270), in wireless-start path; `#ifdef RTCONFIG_NOTIFICATION_CENTER` | none (`wlcnt_chk` is unrelated counters) | killed → no respawn; 4 radios isup, bridges/clients/eapd/hostapd intact `[V]` | **GATE** (0029) |
| **amas_lanctrl** | `start_amas_lanctrl` (≈22550), via `start_amas_services` (AP branch only under `FRONTHAUL_DWB`/`VIF_ONBOARDING`) | `amas_ctl_check` → calls gated `start_amas_lanctrl` | killed → no respawn (12 s window) despite `amas_lanctrl_service_ready=1`; WiFi/VLAN bridges intact `[V]` | **GATE** (0029) |
| **amas_portstatus** | `start_amas_portstatus` (≈26024), `service start_amas_portstatus` verb (`RTCONFIG_CONNDIAG`) | none | killed → no respawn; WiFi/bridges intact `[V]` | **GATE** (0029) |
| **amas_lldpd / lldpd** | `start_amas_lldpd` (≈22817), always called by `start_amas_services`; existing `stop_amas_lldpd=1` nvram (not set) | none | killed both privsep procs → no respawn; WiFi/bridges intact `[V]` | **GATE** (0029) |
| **amas_ssd_cd** | `start_conn_diag_ss` (26036), **only** reached via `start_conn_diag` (26050); the wps-broadcom/wireless "recover" paths require `x_Setting=0` (ours=1) | via `conn_diag_check`→`start_conn_diag` | killed → no respawn; WiFi/bridges intact `[V]` | **GATE — already covered by 0027** (gating `start_conn_diag` stops it) |
| **conn_diag** | `start_conn_diag` (26050) | `conn_diag_check` (10029) → `start_conn_diag` | (gated 0027) | **GATE — done (0027)** |
| **bsd** | `start_bsd` (23378, `BCM_BSD`); needs `smart_connect_x=1` | none | not running in stock (`smart_connect_x=0`); static dead weight on AP — steering owned by webui/802.11v | **GATE** (0030) |
| **roamast** | `start_roamast` (24108); `roamast_disable`/`x_Setting` gates, **but** `STA_AP_BAND_BIND`/`FORCE_ROAMING` build variants ignore `roamast_disable` | `roamast_check` (8380) → `start_roamast` | not running in stock (`roamast_disable=1`); roaming owned by webui/802.11v/k | **GATE** (0030) |

### KEEP (load-bearing — do NOT gate) — confirmed
`eapd` (EAP + wl-event relay; WPA-Enterprise on DEV-SCEP/VID50 depends on it), `hostapd`×4,
`wlceventd`, `mcpd` (IGMP/multicast), `dnsmasq`, `dropbear`/:2222, the `wl`/`dhd` driver, and
**`rc`** itself (owns hostapd-conf generation + `sync_apgx_to_wlunit` slot allocation +
`restart_wireless` — proven in cfg_server RE). All kill-tests left every KEEP daemon untouched.

### Hidden-dependency check
No KEEP daemon depends on a GATE daemon: hostapd confs come from `rc` (not cfg_server/amas);
eapd/wlceventd/mcpd are independent of the amas/notification crew; `amas_ssd_cd` is downstream
of `conn_diag` (both GATE). Removal order is therefore unconstrained for 0029/0030.

## 3. The patches (proven 0024/0028 nvram-`_enable` early-return model)

Each new nvram flag was grepped **unused** in the firmware tree. Default-absent → `0` → retired.
Re-enable with `nvram set <flag>=1 ; nvram commit`. All hunks verified to apply with `patch -p1`
to both the working tree and the pristine vendor HEAD.

### `0029-disable-aimesh-coordinator-daemons.patch` — 4 hunks in `rc/services.c`
Gates the AiMesh/Notification-Center coordinator daemons that *run* on a standalone AP but are
dead weight: `wlc_nt` (`wlc_nt_enable`), `amas_lanctrl` (`amas_lanctrl_enable`), `amas_lldpd`
(`amas_lldpd_enable`), `amas_portstatus` (`amas_portstatus_enable`). Early-return at the top of
each `start_*` (the void ones `return;`, `start_wlc_nt` `return 0`). No watchdog hunk needed:
none has a dedicated `_check`, and `amas_ctl_check`/`conn_diag_check` only re-enter through the
now-gated `start_*`.

### `0030-disable-bandsteer-roaming-daemons.patch` — 2 hunks in `rc/services.c`
Gates `start_bsd` (`bsd_enable`, `return -1` to mirror the no-`smart_connect` path) and
`start_roamast` (`roamast_enable`, placed before the `roamast_disable` check so it also covers
the `STA_AP_BAND_BIND`/`FORCE_ROAMING` build variants that ignore `roamast_disable`). Both are
already off in stock, so this just makes default-off robust at the source.

`amas_ssd_cd`/`conn_diag` need **no new patch** — they are retired transitively by **0027**
(`gtbe98_conn_diag` gate on `start_conn_diag`, which is the sole launcher of `start_conn_diag_ss`).

## 4. Resulting allowed process set (after 0024+0026+0027+0028+0029+0030)

Gated off: `infosvr`(0024), `envrams`(0026), `awsiot`/`networkmap`/`asd`/`conn_diag`/`mastiff`(0027),
`amas_ssd_cd`(via 0027), `cfg_server`(0028), `wlc_nt`/`amas_lanctrl`/`amas_portstatus`/`lldpd`(0029),
`bsd`/`roamast`(0030).

KEEP (the strict WiFi/system core + access + our UI):
`init`, `hotplug2`, `syslogd`/`klogd`, `crond`, `ntp`, `haveged`, kernel `watchdogd`/`wdtd`,
`dropbear`(:2222), `socat`/`httpd.sh` (webui), `wl`/`dhd` driver, `hostapd`×4, `eapd`,
`wlceventd`, `mcpd`, `dnsmasq`, and `rc` (WiFi bring-up + slot allocation).

Stage 2 (build the patched `.pkgtb`) is now a mechanical apply-rebuild-flash of 0024–0030.
Each gate is reversible per-flag via `nvram set <flag>=1`.
</content>
