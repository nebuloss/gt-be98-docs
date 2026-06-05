# Plan — remove the stock Asus services & UI (webui = sole control plane)

> **End goal**: leave running on the router only **SSH (dropbear)** + **our webui**
> and the **strict WiFi/system core**. Everything else (cloud/telemetry, AiProtection/DPI,
> Samba, mDNS, AiMesh, USB, captive portal, WAN failover, **Asus web UI**) is removed.
>
> **Approach: hybrid.** (1) Neutralization without reflashing (nvram gates + firewall) for an
> immediate gain; (2) removal **at the source** via firmware patches (0024/0026 model)
> grouped for the next build. Since we control firmware **and** toolchain, each
> component is handled at the right level: *keep*, *patch the behavior*, or *reverse
> the closed blob and rewrite it cleanly*.

Verified context (2026-06-03, live): router in **AP mode** (`sw_mode=3`, `lan_proto=dhcp`,
LAN IP received from the Ubiquiti gateway). The stock daemons are launched by the monolithic
`rc`/`services.c` binary (not `/etc/init.d/`) and **respawned by `watchdog.c`**; without an nvram
gate, only a firmware patch removes them. Full inventory: [behaviour.md §12.4](../behaviour.md).

## 1. Target state — allowed processes

| Category | Keep |
|---|---|
| Access | `dropbear` (:2222, fallback) |
| Our UI | `socat`/`httpd.sh` (→ :80 eventually, see Phase 4) |
| WiFi core | `hostapd`×4, `eapd`, `mcpd`, `wlceventd`, `wl`/`dhd` drivers |
| System | `init`, `hotplug2`, `syslogd`/`klogd`, `crond`, `ntp`, `haveged`, `watchdogd`/`wdtd` (kernel) |
| Transient | `cfg_server` (WiFi VLAN provisioning — see Phase 3) |

Any daemon outside this list is a **removal target**.

## 2. Disposition per service (verified live)

| Service | Role | Method | Phase |
|---|---|---|---|
| `httpd` (:80) | **Asus web UI** | http_enable=0 already (httpds off); the :80 daemon remains → source patch + socat on :80 | 2/4 |
| `smbd`/`nmbd` (:139/445/137/138) | Samba | **nvram** `enable_samba=0` `smbd_enable=0` | 1 |
| `roamast` | band-steering | **nvram** `roamast_disable=1` (⚠️ `services-start` wrongly uses `roamast_enable=0`) | 1 |
| `wsdd2` (:3702) | WS-Discovery | source patch (no gate) | 2 |
| `avahi-daemon` (:5353) | mDNS | `mdns` gate/patch | 2 |
| `uamsrv` (:8083) | captive portal | source patch | 2 |
| `wanduck` (:18017/18018) | WAN failover (useless in AP) | force `no_need_to_start_wanduck()` / patch | 2 |
| `envrams` (:5152) | remote NVRAM | ⚠️ **0026 patch ineffective on this build** — to diagnose + fix | 2 |
| `awsiot` | AWS/Alexa cloud | source patch (no gate) | 2 |
| `mastiff` | ASUS cloud tunnel | source patch | 2 |
| `bwdpi_check`/`dns_dpi_check` | DPI/AiProtection (useless in AP) | source patch | 2 |
| `asd`, `conn_diag`, `erp_monitor` | ASUS telemetry/diag | source patch | 2 |
| `nt_center`/`nt_monitor`, `protect_srv` | cloud notif/protection | source patch | 2 |
| `networkmap` | client discovery | source patch (our UI builds its own list) | 2 |
| `wps_pbcd`/`wpsaide` | WPS (already `wps_enable=0`) | source patch (respawns despite gate) | 2 |
| `usbmuxd`/`disk_monitor`/`fsmd` | USB/iPhone | source patch / `enable_usb=0` | 2 |
| `amas_*` | AiMesh | source patch (tied to `cfg_server`) | 3 |
| `cfg_server` (:7788) | **WiFi VLAN provisioning** | keep transient → replace/rewrite | 3 |

## 3. Phases

### Phase 0 — done (verified live)
- MAINFH `wl3.1` neutralized (patch **0025**), `infosvr` removed (patch **0024**),
  Asus HTTPS UI off (`http_enable=0`, :8443), `:80→:8080` redirect (firewall-start),
  `acsd`/`acsd2` off, FTP/WPS/telnet/QoS off.

### Phase 1 — neutralization without reflash (webui repo, `scripts/services-start`)
1. **Samba off**: `nvram set enable_samba=0; nvram set smbd_enable=0` + `killall smbd nmbd`.
2. **roamast**: replace `roamast_enable=0` with `roamast_disable=1` (verified effective key).
3. **DROP firewall** on the stock ports still open that we can't yet kill — done in
   `firewall-start` (`:5152` envrams, `:3702` wsdd2, `:8083` uamsrv, `:18017/18018`
   wanduck, `:139/445/137/138` samba); reduces the surface immediately while waiting
   for the Phase 2 patches. `lo` excluded; SSH `:2222` + webui `:8080` stay open.
> ⚠️ The gateless daemons (awsiot, mastiff, DPI, networkmap, envrams, httpd…) are
> **respawned by `watchdog.c`**: a single `killall` doesn't hold. No fragile
> kill-loop — clean removal is in Phase 2.

### Phase 2 — firmware patches (`../gt-be98-firmware/patches/` repo, 0024/0026 model)
`start_X()` in `rc/services.c` (+ `watchdog.c` check) → early-return unless an nvram flag
`X_enable=1`. Patches to write (numbered after 0026):
- `00XX-disable-asus-cloud`: `awsiot`, `mastiff`, `asd`, `conn_diag`, `erp_monitor`,
  `nt_center`/`nt_monitor`, `protect_srv` (groupable).
- `00XX-disable-bwdpi`: `bwdpi_check`, `dns_dpi_check` (AiProtection/DPI).
- `00XX-disable-networkmap`, `00XX-disable-wps`, `00XX-disable-wsdd2-avahi`,
  `00XX-disable-uamsrv`, `00XX-disable-wanduck`, `00XX-disable-usb-services`.
- `00XX-disable-asus-httpd`: don't start the Asus UI daemon (:80).
- **Fix 0026**: diagnose why `envrams` still runs (patch absent from the build?
  respawned by another actor? `envrams_enable` gate not read?) then re-validate.
- Rebuild (`./build.sh`) + flash (webui Firmware card / `hnd-write`) + re-verify the
  live process set.

### Phase 3 — `cfg_server` / WiFi ownership (3 options, to be decided)

> **CORRECTION (VERIFIED LIVE 2026-06-05):** the long-held premise here — that cfg_server
> generates `/tmp/wlX_hapd.conf` and that removing it stops hostapd regeneration — is
> **FALSE**. The hostapd conf generator (`hostapd_config_be.o`, closed) is linked into
> **`rc`** (`rc/Makefile` OBJS/OBJS_WPS_PBCD), and `shared/sysdeps/broadcom/broadcom.c:1515`
> launches `hostapd /tmp/%s_hapd.conf` — both in the **`restart_wireless`/wireless-start
> path, not cfg_server**. Empirical proof: `killall cfg_server` left **all 4 radios
> beaconing, the connected client associated, and `/tmp/wl3_hapd.conf` intact**; the
> **watchdog respawned cfg_server in ~10 s** (new pid). So cfg_server is **NOT load-bearing
> for WiFi operation** on a standalone AP. Its real, separable roles: the GUI config-apply
> IPC (`/var/run/cfgmnt_ipc_socket`) — already replaced by **netctl** (nvram + `rc
> sync_apgx_to_wlunit` + `restart_wireless`); status-JSON publishing
> (`/tmp/{clientlist,aplist,chanspec_*}.json`) — reproducible from `wl`/`hostapd_cli`
> (netctl `clients`/`scan`/`channels`); and AiMesh coordination (`:7788`, `amas_*`,
> `conn_diag`, `wlc_nt`) — pure dead weight here. **Implication:** option (b) (webui owns
> WiFi via netctl) needs NO hostapd-direct rewrite — `restart_wireless` already regenerates
> the confs from nvram with cfg_server gone. The only thing that must change to truly retire
> cfg_server is the **`watchdog.c` respawn gate** (`watchdog.c:9958/10007`,
> `!pids("cfg_server")`) — a Phase-2-style nvram early-return. Verbs: `service
> stop_cfgsync`/`start_cfgsync` (services.c:21595 maps script `cfgsync`).

`cfg_server` was believed the **only** Asus daemon our networks depend on (VLAN bridge +
hostapd conf). Per the correction above, the WiFi dependency is on **`rc`**, not cfg_server.
- **(a) Keep** cfg_server (local, cloudless) as the only tolerated Asus daemon — 90% of the goal.
- **(b) Rewrite**: the webui owns hostapd (writes the confs + bridges via `brctl`);
  revives the abandoned hostapd-direct approach (cf. `phase-b-webui-owns-wifi.md`,
  `phase-b2-sdn-nvram-spec.md`). Full control.
- **(c) Reverse** the `cfg_server` blob and replace it with a clean implementation.
Prerequisite: Phase 2 done (cfg_server is no longer countered by mtlancfg/regenerations).

### Phase 4 — final lockdown
- `socat` directly on **:80** (remove the redirect once the Asus `httpd` is removed).
- Re-block `:8443` (uncomment the `firewall-start` DROP) for defense in depth.
- Verify the process set = §1 list; freeze; document in `behaviour.md`.

## 4. Risks / to investigate
- **Debricking**: any firmware patch goes through the A/B dual-slot (a bad flash falls back
  to the old slot); keep `dropbear` access (independent of the UI) as a safety net.
- **Hidden dependencies**: validate that removing `eapd`/`mcpd`/`wlceventd` is NOT done
  (WiFi core). Verify that no "kept" daemon depends on a "removed" daemon.
- **envrams**: why 0026 has no effect here (Phase 2 priority).
- **wanduck in AP**: confirm whether a gate (`no_need_to_start_wanduck`) already exists before patching.
- **AiMesh**: `amas_*` + `cfg_server` coupled — the removal order matters (Phase 3).
