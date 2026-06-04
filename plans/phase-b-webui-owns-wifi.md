---
name: phase-b-webui-owns-wifi
description: Phase B plan + discovery — make the webui actually create/apply WiFi networks (retire net_apply_all no-op)
metadata: 
  node_type: memory
  type: project
  originSessionId: 4f755f60-617e-4c80-9c5e-2f498ce1bab5
---

**Phase B goal (chosen 2026-06-03, after Phase A done):** make the webui's
`save_network`/`delete_network` ACTUALLY create/apply WiFi networks (SSID+pw+VLAN+
radios), retiring the no-op `net_apply_all()` and dead `hapd_gen.sh`.

**Discovery (the crux):** the SDN master config is **`cfg_server` + `/jffs/.sys/cfg_mnt/common.json`**
(~49KB; defines NetB/NetA/MAINFH/apg/sdn/vlan). cfg_server runs (sw_mode=3 AP,
re_mode=0, x_Setting=1). Chain:
`common.json (master) → derives → nvram apg<N>/sdn_rl/vlan_rl/subnet_rl → closed SDN code at restart_wireless → wlX.Y vifs + lanX_ifnames + bridges → hapd bss`.
So **writing nvram directly does NOT stick** — cfg_server re-derives it from common.json.

A working net = coordinated set: `apg<N>` (enable/ssid/dut_list `<MAC>port>`/security)
+ `sdn_rl` entry `<idx>name>enable>vlan_idx>subnet_idx>apg_idx>…` + `vlan_rl` `<vlan_idx>VID>0>`
+ `subnet_rl` `<subnet_idx>brXX>ip>mask>…`. The rest (`apg_brXX_fh_wlifnames`,
`lanX_ifnames`, `wlX.Y_*`) is DERIVED by closed amas_apg_shared. Live example:
NetB = sdn_idx3/apg3 (dut `<MAC>1>`)=wl3.2 on br30/VLAN30; NetA = sdn_idx4/apg4
(dut `<MAC>21>`) on br20/VLAN20.

**B1 DONE (2026-06-03) — apply mechanism PROVEN, pure nvram, NO common.json, NO firmware patch.**
The GUI's `create_sdn_profile`/`create_sdn_mwl_profile` (httpd/web.c ~43400-43740) does:
1. `web_get_availabel_sdn_profile()` → free sdn_idx/apg_idx/apm_idx/subnet_idx/vlan_idx/vlan_vid.
2. append `sdn_rl` `<sdn_idx>type>1>0>0>apg_idx>0>0>0>0>0>0>0>0>0>0>0>0>0>WEB>0>0` (apm path uses apm_idx field), `vlan_rl` `<vlan_idx>vid>0`, `subnet_rl` `<subnet_idx>br<vid>>addr>mask>1>dhcpmin>dhcpmax>86400>>,>>0>>`, `sdn_access_rl`.
3. set `apg<idx>_<field>` (ssid/security/hide_ssid/...) ; `nvram_set_int("w_Setting",1)`.
4. **`sync_apgx_to_wlunit(NULL)`** ← derives per-vif `wlX.Y_*` from apg. Exposed as CLI **`rc sync_apgx_to_wlunit`** (rc.c:540). THIS was the missing step.
5. `notify_rc("restart_wireless;restart_sdn <idx>")`.
**Verified live:** `nvram set apg3_ssid=X; rc sync_apgx_to_wlunit; nvram commit; service "restart_wireless;restart_sdn"` → wl3.2_ssid=X, live SSID=X. Reverted cleanly. (restart_sdn applies from nvram via get_mtlan; cfg_server did NOT revert the nvram write.)
- security format: `<3>auth>crypto>psk>idx<13>...<16>...<96>...` (per-band; see live apg3/apm2). dut_list: `<MAC>port>` (port = the wlX.Y slot mapping, e.g. NetB `<MAC>1>`→wl3.2).

**REBOOT PERSISTENCE — RESOLVED (2026-06-03):** the committed-nvram change **survives a cold reboot** even though cfg_server did NOT capture it into `common.json` (common.json stayed "NetB", nvram/live stayed "NetBTEST" after boot). So cfg_server does NOT push common.json→nvram at boot on this standalone unit (re_mode=0, no AiMesh). → **B2 needs NO common.json editing and NO firmware patch** — `nvram set apg* + rc sync_apgx_to_wlunit + nvram commit + service "restart_wireless;restart_sdn"` is durable. (Caveat: if the user ever runs the Asus app / AiMesh sync, cfg_server might re-push common.json; not a concern while the webui is the sole control plane. Optionally B2 could also update common.json for belt-and-suspenders, but not required.)

**Plan (B2-B4):**
- B2 (backend): implement `net_apply_all()` in `cgi-bin/lib/networks.sh` — for create: allocate
  free indices (replicate `web_get_availabel_sdn_profile`), compose sdn_rl/vlan_rl/subnet_rl/apg,
  `rc sync_apgx_to_wlunit`, commit, `service "restart_wireless;restart_sdn"`; for edit: set apg
  fields + sync + restart; for delete: splice out the rl entries + clear apg + sync + restart.
  Verify net comes up + **survives reboot** (the open item above).
- B3 (frontend): wire the existing network editor (mostly built) to the now-real apply.
- B4: validate + delete dead code (`hapd_gen.sh`, the no-op `net_apply_all` return 0).

Tools we have: working firmware build+flash (webui flash feature / hnd-write), the
open-seam patch method ([[next-phase-firmware-re]]), [[firmware-flash-mechanism]].
If cfg_server can't be driven cleanly from outside, fallback is a firmware patch
(open seam) to honor a webui config source — but try the common.json/cfg_server
route first (no reflash).
