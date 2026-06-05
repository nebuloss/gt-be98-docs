# cfg_server — reverse-engineering for network config replacement

> RE of `/usr/sbin/cfg_server` (ARM 32-bit, stripped, 1.2M) — static (objdump/nm/
> strings) + live read-only observation via SSH `admin@10.0.0.8:2222`.
> Goal: replace ONLY the **network-configuration** role (WiFi/VLAN), dropping the
> AiMesh/coordination bulk. Secrets noted `<REDACTED>`.

## 1. What cfg_server is — and what you actually use

`cfg_server` is the **AiMesh/Guest-Pro config coordinator**. Live nvram proves
this unit is a **standalone AP**, not a mesh node:
`cfg_master=1, sw_mode=3 (AP), re_mode=0, amas_bdl=` (empty). So the **majority**
of cfg_server is dead weight here:

- ❌ Not needed: mesh node coordination (TCP/UDP `:7788`, TLS via
  `/etc/cfg_mnt/{key,pub}.pem`), `conndiag`/`rast`/`amas_lib`/`nbr` IPC,
  `/jffs/.sys/cfg_mnt/` node state, sqlite client DB, LLDP topology, band-steering
  daemon (`bsd`) orchestration.
- ✅ Needed (the replaceable core): turn the **network config** (SSID / security /
  band / VLAN) into running WiFi. That's a small, deterministic job.

## 2. The driver interface is PUBLIC (key result)

cfg_server programs the radios through the **standard Broadcom `wl` API** — the
same one the `wl` CLI and open `wlioctl.h` headers document — NOT a secret channel:

```
wl_ioctl(ifname, cmd, buf, len)     wl_iovar_get / wl_iovar_getbuf
wl_nvname(...)   # maps nvram key -> wl iovar
wl_cap / wl_get_bw_cap / wl_get_chlist_band / wl_check_unii4_band
nvram_get / nvram_set / nvram_commit
```

→ The WiFi control plane is reimplementable against `wl_ioctl`/iovars + nvram.
hostapd handles only the WPA handshake (one `hostapd /tmp/wlX_hapd.conf -B` per
radio; `eapd` relays EAP). The **`wl` driver** owns BSS creation + bridge
membership, set at init from nvram (see §4).

## 3. The deterministic nvram → /tmp/wlX_hapd.conf mapping

cfg_server's main network output is one hostapd conf per radio, generated from
nvram. Verified mapping (wl3 = 2.4G example):

| hostapd.conf key | nvram source | notes |
|---|---|---|
| `interface=` | `wlX_ifname` | `wl0`..`wl3` |
| `bridge=` | bridge of wlX in `lan*_ifnames` | br0 / br20 / br30 |
| `hw_mode=` | `wlX_nband` | 1→`a`(5G), 2→`g`(2.4G), 4→6G |
| `channel=` | `wlX_chanspec` | 0 = auto |
| `country_code=` | `wlX_country_code` | e.g. `E0` |
| `ssid=` | `wlX_ssid` | |
| `ignore_broadcast_ssid=` | `wlX_closed` | hidden |
| `wpa=` / `wpa_key_mgmt=` | `wlX_auth_mode_x` | `psk2`→`WPA-PSK`, `sae`→`SAE`, `psk2sae`→`WPA-PSK SAE SAE-EXT-KEY` |
| `wpa_pairwise=` | `wlX_crypto` | `aes`→`CCMP`, `aes+gcmp256`→`CCMP GCMP-256` |
| `wpa_passphrase=` / `sae_password=` | `wlX_wpa_psk` | |
| `ieee80211w=` (MFP) | `wlX_mfp` | 6 GHz forces SAE+MFP |
| `ieee80211be=1` | radio caps | Wi-Fi 7 |

Guest/VLAN BSS (`wlX.Y`) use `wlX.Y_*` keys + the SDN (`apgN_*`, `sdn_rl`,
`vlan_rl`) — see [behaviour.md](behaviour.md) §5/§12.2 and
[topology.md](topology.md).

## 4. Bridge / VLAN membership (the one hard part)

Per [behaviour.md](behaviour.md) §11: `brctl` CANNOT move a `wl*` interface; the
**driver** sets BSS↔bridge membership at init from `lan_ifnames` / `lanN_ifnames`
(+ apg/sdn). Live:
```
lan_ifnames  = eth0..3 wl0 wl1 wl2 wl3 wl3.1 wl3.4      # br0 (native)
lan1_ifnames = wl3.3 eth0.30 .. wl3.30                  # br30 (VLAN30)
lan2_ifnames = wl3.5 wl0.2 wl1.2 eth0.20 .. wl3.20      # br20 (VLAN20)
```
So a VLAN change = edit these nvram lists (+ apg/sdn) then re-init the driver.
NB: stock `mtlancfg`/`cfg_server` regenerate `lanN_ifnames` on apply — to own
this you must disable them (single-AP only).

## 5. Minimal replacement (single AP, no mesh)

You do NOT need cfg_server. A small open helper (in webui-go or a script) can:

1. **Config in** → set nvram: `wlX[.Y]_{ssid,auth_mode_x,crypto,wpa_psk,bss_enabled,
   closed}`, `lan*_ifnames` (bridge/VLAN), and `apgN_*`/`sdn_rl`/`vlan_rl` for
   guest VLANs.
2. **Generate** `/tmp/wlX_hapd.conf` from nvram (mapping §3).
3. **Apply**:
   - light (no outage, [behaviour.md](behaviour.md) §7b): `wl -i wlX.Y ssid|closed|bss`,
     `hostapd_cli -i wlX reload|reload_wpa_psk`.
   - heavy (new BSS / VLAN membership): set nvram → re-init the wl driver + (re)start
     the per-radio `hostapd`. The driver-init sequence (what `restart_wireless` does
     for wireless, minus cfg_server) is the remaining RE item — candidates: `wlconf
     wlX up`, `wl … bss up`, `eapd`.
4. **State out** (optional, for the UI): cfg_server publishes `/tmp/*.json`
   (`clientlist`, `aplist`, `chanspec_*`); reproduce with `wl assoclist` /
   `wl -i wlX.Y assoclist` + `hostapd_cli all_sta`.

**Verdict:** the WiFi/VLAN config layer is open-API + deterministic nvram→hapd →
fully replaceable. The remaining unknown is only the **driver re-init sequence**
(§5.3 heavy path); everything else is documented here.

## 6. Load-bearing analysis on a standalone AP (VERIFIED LIVE 2026-06-05)

The question "what actually breaks if cfg_server dies?" — settled both statically and live.

**cfg_server does NOT own the WiFi bring-up.** The closed hostapd-conf generator
(`hostapd_config_be.o`) is linked into **`rc`** (`rc/Makefile` OBJS/OBJS_WPS_PBCD), and
`shared/sysdeps/broadcom/broadcom.c:1515` does the `hostapd /tmp/%s_hapd.conf &` launch —
all in the **`restart_wireless`/wireless-start** path. So `rc`, not cfg_server, regenerates
the confs and starts hostapd. The slot allocator `sync_apgx_to_wlunit` is likewise exposed
through **`rc`** independently of the daemon.

**Live proof:** `killall cfg_server` →
- all 4 radios stayed `isup=1` and beaconing; the associated client stayed associated;
  `/tmp/wl3_hapd.conf` persisted unchanged. cfg_server is **not in the WiFi data path**.
- the **`watchdog.c` respawned cfg_server in ~10 s** (new pid) — `watchdog.c:9958` /
  `:10007` gate on `!pids("cfg_server")` under AP/router mode. So a bare `killall` never
  holds on stock fw; truly retiring it needs an nvram early-return in that watchdog gate.

**Separable roles of cfg_server (none load-bearing for WiFi):**
| Role | Live artifact | Open replacement |
|---|---|---|
| GUI config-apply IPC | `/var/run/cfgmnt_ipc_socket` (unix STREAM) | **netctl** (nvram + `rc sync_apgx_to_wlunit` + `restart_wireless`) |
| Status publishing | `/tmp/{clientlist,allwclientlist,aplist,chanspec_*,wiredclientlist}.json` | netctl `clients`/`scan`/`channels` from `wl`+`hostapd_cli` |
| AiMesh coordination | TCP+UDP `:7788`; siblings `wlc_nt`,`amas_lanctrl`,`amas_ssd_cd`,`amas_portstatus`,`conn_diag` | dead weight on a standalone AP — drop |
| Wi-Fi bring-up | — | **already `rc`'s job**, not cfg_server's |

Control verbs: `service stop_cfgsync` / `service start_cfgsync` (`services.c:21595` maps the
`cfgsync` script to `stop/start_cfgsync`; `rc stop_cfgsync` is NOT a verb — that's a C fn).

**Bottom line:** on this standalone AP, cfg_server is retireable without touching WiFi —
the prerequisite is neutralizing its **watchdog respawn**, not finding a hostapd replacement
(`rc`/`restart_wireless` already covers that). See
[plans/plan-remove-stock-services.md](plans/plan-remove-stock-services.md) Phase 3.
