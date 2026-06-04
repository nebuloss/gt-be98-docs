# Plan — clean firmware tweaks for full hardware control over WiFi

> **Status:** design, source-grounded (read-only study of `../gt-be98-firmware`,
> upstream pinned at `ad42d5e…`, 2026-06-04) + live validation on the router.
> **Goal:** make the **webui the sole control plane** for WiFi, with (1) no hidden
> main SSID on the admin LAN, (2) the first user net adopting the primary radio BSS
> bound to its VLAN, and (3) create/edit of a network **without the global
> `restart_wireless` outage** — all via *minimal, reversible, nvram-gated* firmware
> patches in the established 0024–0027 style. Patches live in `../gt-be98-firmware`
> (authored by the firmware agent); this plan is the webui-side spec/contract.

Companion docs: [main-wifi-admin-lan.md](../main-wifi-admin-lan.md) (live experiments
E1–E8), [wifi-apply-no-outage.md](../wifi-apply-no-outage.md) (per-radio hostapd).

## 1. Architecture map — who owns WiFi (open vs closed)

SDN/WiFi provisioning is **three layers, two of them closed blobs**:

| Layer | Owner | Open? | Role |
|---|---|---|---|
| A. apg/sdn → `wlX.Y_*` nvram | `libcfgmnt.so` `sync_apgx_to_wlunit`/`apmx_apgx_to_wlxy` | **closed** | translates `sdn_rl`/`vlan_rl`/`subnet_rl`/`apg*` into per-BSS `wlX.Y_*` nvram |
| B. `wlX_hapd.conf` gen + BSS bring-up | `hostapd_config_be.o` + `wlconf` | **closed** | writes `/tmp/wlX_hapd.conf`, emits `interface=`/`bss=`/`bridge=`, launches hostapd |
| C. L3 per-SDN (DHCP/DNS/route/fw) | `rc/sdn.c` `handle_sdn_feature()` | **open** | dnsmasq/iptables/ip-rule per VLAN |
| D. AiMesh config distribution | `cfg_server`/`cfg_client` | **closed** | syncs config across mesh via `common.json`; **respawned by watchdog** |

**The single open chokepoint** that the closed generator (B) is forced to read is
`get_all_lanifnames_list()` — `shared/wlif_utils_ax.c:814-858` (the patch-0025 hook).
It returns the concatenation of `lan_ifnames` + `lan1_ifnames` + `lan2_ifnames` …,
and the closed blob derives **each BSS's bridge positionally** from *which `lanN_ifnames`
segment* the ifname came from (`lan_ifnames`→`br0`, `lanN_ifnames`→`br<N>`). This is
the lever for everything below: suppress an ifname → no BSS, no bridge; move an ifname
to another `lanN_ifnames` → the blob emits `bridge=br<that>`.

Key facts established (cite for the patch author):
- The primary `wlX` lands on `br0` because open code `rc/init.c:1214-1221` folds every
  `wl_vifnames` entry into `lan_ifnames` (= br0), and the blob picks the radio's root
  interface as the primary head. **Verified E7:** moving `wlX` between `lanN_ifnames`
  via nvram alone is *reverted* by the closed stack on `restart_wireless` — so the
  re-bucketing must be done **in firmware** (inside `get_all_lanifnames_list`), where
  it survives.
- SSID/security of the primary *are* `wlX_*`-nvram driven and persist (E6); only the
  **bridge** can't be moved from nvram (E7) → needs the patch.
- `cfg_server` (D) is **not required** for single-router WiFi bring-up, but the
  watchdog respawns it (`watchdog.c:10009`, gated on `AMAS_CAP`) and it can overwrite
  `wlX.Y_*` nvram from `common.json`. Layer A's `sync_apgx_to_wlunit` lives in
  `libcfgmnt.so` and **is** needed (the webui already calls `rc sync_apgx_to_wlunit`).

## 2. Design principles (match the 0024–0027 house style)

1. **Minimal & at the source** — smallest hunk in open code; never reverse the blobs.
2. **nvram-gated, default = no-op** — every patch reads a new nvram key, default
   unset → identical to stock, so a bad build falls back cleanly (A/B dual-slot).
3. **Reversible** — re-enable/disable purely via `nvram set`.
4. **Idempotent apply** — add a grep-sentinel in `tools/apply-patches.sh` and an
   entry in `GTBE98_FUNCTIONAL_PATCHES`; document in `patches/README.md`.
5. **Keep the closed primitives we still want** (`sync_apgx_to_wlunit`, `wlconf`, the
   hapd generator) — we only *steer their inputs* and *neutralize* the parts that
   fight us (forced primary bridge, cfg_server respawn, global-only restart).

## 3. Proposed patches (next free number = 0028)

### 0028 — primary-BSS bridge control (TWO different hook points)

> **Design corrected by a cross-compiled live probe** (see § Validation tooling).
> A probe linking the staged `libshared.so` showed `get_all_lanifnames_list()` returns
> a **flat** ifname list with no bridge boundaries (`lan_ifnames`+`lan1`+`lan2`
> concatenated, `wl3.1` already stripped by 0025). So the closed blob must **re-read
> `lanN_ifnames` from nvram** to assign each BSS's bridge — the list only controls
> *which* BSS exist, not their bridge. That splits 0028 into two patches:

**0028a — suppress** (`shared/wlif_utils_ax.c`, extends the 0025 block): listing an
ifname in `hapd_exclude_ifnames` removes its `interface=`/`bss=` stanza (proven for
`wl3.1`). For "no WiFi by default" we'd suppress the *primary* `wlX`. ⚠️ *Live-test
post-flash* (`validate-firmware.sh --test-suppress`): suppressing the radio **head**
may make the blob skip the whole radio — if so, park the radio another way.

**0028b — re-bucket the primary to a VLAN** (`rc/init.c`, NOT `wlif_utils_ax.c`):
**Why init.c:** a live test moved `wl1` from `lan_ifnames` to `lan2_ifnames` via nvram
+ `restart_wireless` → the change was **reverted** and `wl1.0` stayed on `br0`. Reason:
`restart_wireless` → `init_nvram()`/`wl_defaults()` **rebuilds `lan_ifnames`**, folding
`wl_vifnames` into it at `rc/init.c:1214-1221`. So a persistent re-bucket must happen
**there**: after the fold, move primaries named in a new nvram `hapd_primary_bridge_map`
out of `lan_ifnames` and into the target `lanN_ifnames`. The blob then re-reads the
amended lists and emits `bridge=br<VLAN>`. This is why nvram-alone (E7) could not work,
and why the original "re-bucket inside `get_all_lanifnames_list`" idea would **not**
have moved the bridge (the blob ignores that list's order for bridging).

Sentinels for `apply-patches.sh`: `hapd_exclude_ifnames` (0028a, already present) and
`hapd_primary_bridge_map` (0028b). House-style comment + default no-op.

**Realizes:** goals (1) no admin-LAN main SSID, and (2) first net adopts the primary
on its VLAN — 0028b binds the primary radios into the first user net's VLAN.

### 0029 — per-radio apply (`restart_wireless_unit`) to kill the global outage

**Files:** `rc/lan.c` (new `restart_wireless_unit(int unit)`), `rc/rc.c` (dispatch
next to the `restart_wireless` case at `:4370`), and lift the GT-BE98 exclusion on the
`gen_wl` action / `generate_wl_para` (`rc/rc.c:955-967`, `rc/sysdeps.h:38`).

**Rationale (verified):** `restart_wireless()` (`rc/lan.c:6569`) is global because of
the `stop_lan_wl`→`start_lan_wl`→`restart_wl` trio (`:6724/6777/6779`) = full per-radio
**wl driver re-init + bridge teardown/rebuild** for all bands at once. But hostapd is
**decoupled** from the driver: `set_wlan_service_status` respawns one radio's
`hostapd … -B` (`broadcom.c:1513-1518`), and `runtime_onoff_wps` already drives
per-radio `hostapd_cli reload/update_beacon/disable/enable`
(`wps-broadcom.c:1019-1027`).

`restart_wireless_unit(unit)` does, for one radio only:
1. `generate_wl_para(ifname, unit, -1)` → regenerate just that radio's `/tmp/wlX_hapd.conf`.
2. If only SSID/visibility changed → `hostapd_cli -i wlX update_beacon` (**zero RF drop**).
   If security/AKM changed → `hostapd_cli -i wlX disable && … enable` (one-band blip).
   If PHY (channel/bw/country) changed → `wl -i wlX down/up` (one-band, still no global).
3. Never touch the other three radios; never `stop_lan_wl`.

**Caveat (verified):** a pure-hostapd reload applies SSID/security/enabled-state for an
**existing** BSS but does **not** create/move VLAN bridges (that's `restart_sdn`). So:
- *Edit* an existing net's SSID/password/visibility/enable → no-outage via 0029.
- *Create/delete* a VLAN-backed net → still needs the SDN path (`sync_apgx_to_wlunit`
  + `restart_sdn`), but can scope the wireless half to the affected radios via 0029
  instead of global `restart_wireless`.

**Realizes:** goal (3) outage-free edits.

### 0030 — neutralize `cfg_server` respawn (webui owns provisioning)

**Files:** `rc/watchdog.c` (`:10009-10022` cfg_server respawn branch) + `rc/services.c`
`start_cfgsync()` (`:25884`). House-style early-return guard keyed on a new nvram
(e.g. `gtbe98_cfgsync` default 0 → don't start/respawn `cfg_server`).

**Why:** with cfg_server gone, nothing regenerates `wlX.Y_*` from `common.json` behind
the webui's back, and nothing auto-fires `restart_wireless` on mesh events — the
webui's nvram writes + scoped applies become authoritative. **Keep** `libcfgmnt.so`'s
`sync_apgx_to_wlunit` (still invoked by the webui) — we disable the *daemon*, not the
*library*. Single-router only (no AiMesh) — acceptable for this deployment.

⚠️ Validate that disabling cfg_server doesn't break first-boot SDN materialization;
if `apg_br_info`/bridge creation depends on a cfg_server pass, keep cfg_server for the
initial create and only suppress its *steady-state respawn*, or drive the bridge
creation from `rc rc_service restart_sdn` (open, `rc/sdn.c`).

### (optional) 0031 — disable the Asus `httpd` (:80) at the source

Per `plan-remove-stock-services.md` Phase 2/4 — once socat moves to :80. Out of scope
for WiFi control but noted for the same build.

## 4. End-state behaviour (how the goals compose)

- **Boot, no nets defined:** webui config store empty → primaries suppressed/parked
  (0028) → **no WiFi**, radios enabled, box managed over the wired uplink (E4).
- **Create first net (e.g. NetA/VLAN 20):** webui writes `wlX_ssid`/security +
  sets `hapd_ifname_bridge_map` to map the primaries onto VLAN 20's `lanN` (0028) →
  the primary BSS becomes NetA on `br20`, **no hidden admin SSID** → apply via
  SDN path for the new bridge, scoped wireless via 0029.
- **Edit an existing net (SSID/password/visibility):** webui rewrites the radio's
  hapd conf + `restart_wireless_unit` (0029) → **no outage** (or one-band blip for
  security).
- **No `cfg_server`** (0030) overwriting nvram or forcing global restarts.

## 5. Validation plan (per patch, on the live lab router)

**Validation tooling — cross-compile + live-probe (no flash).** `tools/fw-build-probe.sh`
cross-compiles a small C probe against the firmware's *staged* libs using the repo's own
softfp toolchain, pushes it to the router and runs it — exercising real firmware functions
on live hardware without flashing. Example probe `tools/firmware-probes/probe_lanifnames.c`
calls `get_all_lanifnames_list()` to show exactly what the closed hapd generator consumes
(this is how the 0028 split above was discovered: flat list, `wl3.1` already stripped by
0025, bridges re-read from nvram). Use this loop to validate patch *logic* before the
firmware agent bakes it in; for code that lives in a dynamically-linked lib (e.g.
`libshared.so`/`get_all_lanifnames_list`) the same lib can be rebuilt and bind-mounted over
`/usr/lib/libshared.so` on the router for an end-to-end test (a reboot reverts it).

Automated harness: **`tools/validate-firmware.sh`** (busybox, runs on the router;
read-only by default, `--apply` runs the disruptive checks on an idle radio and
restores). It encodes the acceptance criteria below and prints PASS/FAIL/SKIP. The
nvram-key / rc-action names at the top of the script are the *proposed* names — align
them with the firmware agent's final choices before relying on the result.

For each patch: build → flash inactive slot (`hnd-write`, exit 99 = OK) → run
`tools/validate-firmware.sh --apply` → verify, with `dropbear` (:2222, wired) as the
always-available rescue net (debrick = A/B fallback).

- **0028:** `nvram set hapd_ifname_bridge_map="wl0:lan2_ifnames …"; restart_wireless`
  → check `/tmp/wl0_hapd.conf` head emits `bridge=br20`; `brctl show` puts `wl0.0` in
  `br20`, not `br0`; survives a second `restart_wireless` (the E7 failure becomes a
  pass). Then test pure-suppress of a primary and watch for the "skip whole radio" log.
- **0029:** edit one radio's SSID, `rc restart_wireless_unit 0`; confirm other radios
  stay associated (continuous ping from a client on another band), and `wlready`
  semantics still satisfy the front's `get_apply_status`.
- **0030:** confirm `cfg_server` stays dead across a watchdog cycle and a reboot, that
  `rc sync_apgx_to_wlunit` still works, and that creating a net via the webui still
  builds the VLAN bridge (via `restart_sdn`).

## 6. Risks / open questions

- **Suppressing the radio head** may disable the whole radio in the blob (0028 caveat)
  — decide suppress-vs-rebucket per live test.
- **cfg_server initial dependency** for first-time bridge creation (0030 caveat).
- **`generate_wl_para` on GT-BE98**: confirm the closed def is linked for this model
  before relying on the `gen_wl`/`restart_wireless_unit` path (it's externed in
  `sysdeps.h:38` but the CLI is `#if`-gated off for GT-BE98).
- **MLO/11be grouping**: the blob groups primary+virtuals and MLD links; re-bucketing
  or suppressing the primary may interact with MLO (`mlo_toggle_fb`). Test with MLO on
  and off.
- **AiMesh permanently off** is implied by 0030 — fine for this single-router site.

## 7. Sequencing

1. **0029 first** (per-radio apply) — pure win, lowest risk, no behaviour change until
   used; unblocks no-outage edits immediately.
2. **0028** (primary bridge control) — the core security/“adopt primary” feature;
   needs the most live testing (suppress vs rebucket, MLO).
3. **0030** (cfg_server) — last, once the webui fully owns the apply path so nothing
   regresses when the daemon goes away.
4. Webui side (`cgi-bin/lib/networks.sh`): **pre-staged** — `net_apply_one` already
   branches to a scoped per-radio apply (`net_sdn_scoped_apply` → `rc
   restart_wireless_unit`) for edits, gated behind the firmware capability +
   `nvram webui_scoped_apply=1` (default off → no behaviour change yet). When 0028/0029
   land: flip the flag, and extend `net_sdn_create`/`update` to also set
   `hapd_ifname_bridge_map` for the primary-adopts-first-net binding. A webui-owned
   hostapd generator (`cgi-bin/lib/hapd_gen.sh`) is prototyped and live-validated (AP
   reaches `ENABLED`); it becomes the authoritative writer only after 0030 removes
   `cfg_server`/the stock hapd-monitor.
