# Patch 0028 — retire `cfg_server` by default (the exact spec)

> Ready-to-apply firmware patch + rollout, built on the **verified** finding that
> `cfg_server` is **not load-bearing for WiFi** on a standalone AP
> (see [../cfg_server_re.md](../cfg_server_re.md) §6 and
> [plan-remove-stock-services.md](plan-remove-stock-services.md) Phase 3). Mirrors the
> existing `0024-infosvr-disable-by-default` / `0026-envrams-disable-by-default` model
> (nvram `*_enable` early-return, "Fork GT-BE98" comment). Next free number: **0028**
> (0027 = disable-asus-cloud-telemetry).

## Why this is safe (evidence)

| Concern | Reality (verified 2026-06-05) |
|---|---|
| "cfg_server generates `/tmp/wlX_hapd.conf`" | **False.** `hostapd_config_be.o` (closed gen) is linked into **`rc`** (`rc/Makefile` OBJS/OBJS_WPS_PBCD); `shared/sysdeps/broadcom/broadcom.c:1515` launches `hostapd /tmp/%s_hapd.conf` — the **`restart_wireless`** path. |
| "the slot allocator needs the daemon" | **False.** `sync_apgx_to_wlunit` is in **`libcfgmnt`** (`cfg_mnt/cfg_mtlan.h`), linked into `rc` (`rc/Makefile:357 -lcfgmnt`). Live: `rc sync_apgx_to_wlunit` ran with cfg_server **dead** (exit 0, json byte-identical). |
| "WiFi drops if cfg_server dies" | **False.** `killall cfg_server` → all 4 radios stayed beaconing, client stayed associated, `/tmp/wl3_hapd.conf` intact. |
| What actually stops | The GUI config-apply IPC (`/var/run/cfgmnt_ipc_socket`), status-JSON publishing (`/tmp/{clientlist,aplist,chanspec_*}.json`), AiMesh `:7788`. All replaced by **netctl** + webui. |
| Why a patch (not just `killall`) | `watchdog.c:cfgsync_check()` **respawns** cfg_server in ~10 s. The gate below stops the respawn. |

## The patch (`patches/0028-cfgmnt-disable-by-default.patch`)

Two hunks, both gated on a single new nvram flag **`cfgmnt_enable`** (verified unused in the
tree). Default-absent → `0` → cfg_server retired. Re-enable with `nvram set cfgmnt_enable=1`.

```diff
diff --git a/release/src/router/rc/services.c b/release/src/router/rc/services.c
--- a/release/src/router/rc/services.c
+++ b/release/src/router/rc/services.c
@@ -25884,6 +25884,15 @@ int start_cfgsync(void)
 	char *cfg_server_argv[] = {"cfg_server", NULL};
 	char *cfg_client_argv[] = {"cfg_client", NULL};
 	pid_t pid;
 	int ret = 0;
 
+	/* Fork GT-BE98 : cfg_server (coordinateur AiMesh/Guest-Pro) retiré par défaut.
+	 * Sur AP autonome il n'est PAS sur le chemin WiFi : rc/restart_wireless génère
+	 * /tmp/wlX_hapd.conf (hostapd_config_be.o lié à rc) + lance hostapd, et l'allocateur
+	 * sync_apgx_to_wlunit vient de libcfgmnt liée à rc — pas du démon (vérifié live :
+	 * killall cfg_server laisse les 4 radios en service). netctl/webui possèdent l'apply
+	 * et le statut. Réactiver : nvram set cfgmnt_enable=1 ; nvram commit. */
+	if (!nvram_get_int("cfgmnt_enable"))
+		return 0;
+
 #ifdef RTCONFIG_MASTER_DET
 	if (nvram_match("cfg_master", "1") && (is_router_mode() || access_point_mode()))
 #else
diff --git a/release/src/router/rc/watchdog.c b/release/src/router/rc/watchdog.c
--- a/release/src/router/rc/watchdog.c
+++ b/release/src/router/rc/watchdog.c
@@ -9928,6 +9928,11 @@ void cfgsync_check()
 	char reboot[sizeof("255")];
 	char upgrade[sizeof("255")];
 	unsigned int cfg_pause = nvram_get_int("cfg_pause");
 	char value[sizeof("9999999")];
 	int pid_by_file = 0, pid_by_name = 0;
 
+	/* Fork GT-BE98 : ne pas relancer cfg_server s'il est retiré (cf. start_cfgsync). */
+	if (!nvram_get_int("cfgmnt_enable"))
+		return;
+
 	memset(reboot, 0, sizeof("255"));
```

Notes:
- `start_cfgsync()` is the **single** funnel for every cfg_server launch — boot
  (`services.c` start sequence) **and** every watchdog-triggered `notify_rc("start_cfgsync")`.
  Gating it there is the real neutralization; the `cfgsync_check()` gate just stops the
  watchdog from spamming `notify_rc` once per cycle.
- Same `cfg_master`/`access_point_mode` decl block as `start_infosvr` in 0024 → the
  early-return leaves a couple of unused locals (`cfg_*_argv`, `pid`); harmless warning,
  identical to 0024's pattern.
- This also neutralizes `cfg_client` (RE side) — irrelevant here (`re_mode=0`).

## Rollout (the prerequisite matters)

Disabling cfg_server removes the **GUI apply path** and the **status JSON**. Do NOT flash
this until the open stack owns both, or pre-seed `cfgmnt_enable=1` and flip later:

1. **Before retiring** — confirm webui-go + netctl cover:
   - config apply → `netctl net-create/net-delete/net-edit/chanspec` (nvram + `rc
     sync_apgx_to_wlunit` + `restart_wireless`); the GUI's `cfgmnt_ipc_socket` is no longer used.
   - status → `netctl clients/scan/channels/events` reproduce `/tmp/{clientlist,aplist,
     chanspec_*}.json` from `wl`/`hostapd_cli`.
2. **Stage without reflash** (reversible test): `nvram set cfgmnt_enable=0` is the default,
   but on a stock unit cfg_server is already running — to dry-run the retired state live:
   `killall cfg_server` then within the ~10 s watchdog window confirm WiFi + `rc
   sync_apgx_to_wlunit` still work (already verified). The watchdog will respawn it; that's
   expected until the patch is in.
3. **Apply the patch**, rebuild `rc`, flash (A/B dual-slot — a bad flash falls back). On the
   new image cfg_server stays down; `dropbear`/SSH on ethernet remains the safety net.
4. **Keep stock behaviour** at any time: `nvram set cfgmnt_enable=1 ; nvram commit` →
   next boot/`service start_cfgsync` brings cfg_server back. Full rollback = drop the patch.

## What you lose, and the open replacement

| cfg_server role | Live artifact | Replacement |
|---|---|---|
| GUI config-apply IPC | `/var/run/cfgmnt_ipc_socket` | netctl (nvram + `rc sync_apgx_to_wlunit` + `restart_wireless`) |
| Status publishing | `/tmp/{clientlist,allwclientlist,aplist,chanspec_*,wiredclientlist}.json` | `netctl clients/scan/channels/events` |
| AiMesh coordination | TCP/UDP `:7788`, `amas_*`, `conn_diag`, `wlc_nt` | dead weight — drop (separate patches) |
| WiFi bring-up / allocation | — | already `rc`'s job (no change needed) |

The one open item if a future deployment serves L3 locally (this AP trunks VLANs to an
upstream L3, so it doesn't today): the SDN per-bridge `dnsmasq` is also started by `rc`
(not cfg_server), so it is unaffected by this patch.
