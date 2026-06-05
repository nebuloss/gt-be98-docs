# Client / band steering — the open 802.11v BTM control plane

> **VERIFIED LIVE 2026-06-05** on the GT-BE98. WiFi client steering can be driven entirely
> from open tools (`hostapd_cli` WNM verbs) with **no** ASUS `bsd` band-steering daemon.
> Wired into `netctl` as **`steer`** + **`steer-neighbors`**.

## The mechanism

802.11v **BSS Transition Management (BTM)**: the AP sends a unicast WNM action frame to an
associated STA suggesting it move to another BSS (another band, or a less-loaded AP). The STA
decides, but `abridged`+`pref` strongly bias it, and `disassoc_imminent` forces the issue.
hostapd exposes the whole verb set (confirmed live via `hostapd_cli help`):

```
bss_tm_req <sta> ...      send a BSS Transition Management Request
disassoc_imminent          mark the STA disassoc-imminent (forced steer)
ess_disassoc               ESS disassociation imminent
set_neighbor / show_neighbor / remove_neighbor   the 11k/11v neighbor DB
```

The source BSS must advertise **BSS Transition**. Stock ASUS confs **don't** set
`bss_transition=1` (ASUS uses the legacy `bsd` daemon instead). But it is **runtime-settable**:
`hostapd_cli -i <bss> set bss_transition 1` → **OK** [V]. `netctl steer` enables it
automatically (idempotent).

## Verified live [V]

On a disposable SAE BSS (`wl2.2`, 6 GHz) as the steer source:
- `set_neighbor` → **OK**; `show_neighbor` lists the DB. With `rrm_neighbor_report=1` the BSS
  **auto-registers its own** neighbor entry:
  `60:cf:84:38:87:be ssid=72652d737465657236 nr=60cf843887be8f0000008301040603000000`.
- `netctl steer wl2.2 <sta> wl3.3` resolved target **wl3.3**'s BSSID `ba:cf:84:38:87:b3` and
  derived **opclass=81 chan=1** (2.4 GHz) from its chanspec; `wl0.1` → opclass=128 chan=36
  (5 GHz); raw BSSID + explicit `134 5` (6 GHz) also accepted.
- `bss_tm_req` is **dispatched**; it returns **FAIL** here only because **no STA is
  associated** on the test BSS (and there is no driveable on-box client — see below). The
  authenticator-side primitive (verb parsed, target resolved, BTM frame built/sent) is proven;
  a real associated client returns **OK** and moves.

### Why no full round-trip on-box (honest limit)
No client is associated to any BSS right now, the `bsd` daemon is **not running**, and the
router's `wpa_supplicant` is **v0.6.10 (wired/roboswitch only)** — there is no way to bring up
a real WiFi station on-box. So a true "client moved" observation needs an external client
(phone/laptop) associated to `test`/a disposable BSS, then `netctl steer <bss> <its-mac>
<target>` → watch it roam (and `netctl events` shows the DISCONNECT/CONNECT round-trip).

## `netctl steer`

```
netctl steer <src-bss> <sta-mac> <target-bss|target-bssid> [opclass chan] [--kick]
netctl steer-neighbors <bss>          # show the BTM neighbor DB
```

- **target = a `wlX.Y` ifname on this AP** → BSSID + op_class/channel auto-derived from its
  chanspec (band steering between this AP's own BSSes). Global operating-class mapping
  (best-effort 80/160 MHz): **2.4 GHz=81, 5 GHz=128, 6 GHz=134**; primary channel from the
  target's `wl chanspec`.
- **target = a raw BSSID** → optionally pass `opclass chan` (steer to another AP).
- `--kick` adds `disassoc_imminent=1 disassoc_timer=30` (forced steer — the STA must leave).
- Enables `bss_transition` on the source BSS first; refuses protected interfaces (`wlX.0`).
- Reports hostapd's reply: **OK** = BTM frame sent; **FAIL** = STA not associated on `<src>`
  (or the STA doesn't support BTM).

The BTM hint travels in the inline `neighbor=<bssid>,0,<opclass>,<chan>,9` field of the
`bss_tm_req` (phy 9 = HE) — no separate `set_neighbor` needed (and `od` isn't on-box, so the
tool builds it inline).

## The legacy ASUS path (for contrast, not used)

nvram has the stock band-steering-daemon config — **`bsd` is configured but not running** on
this standalone AP:
```
bsd_ifnames=wl3.1 wl0.1 wl1.1   bsd_role=3   bsd_scheme=2   roamast_enable=0  roamast_disable=1
wl0_bsd_steering_policy=0 5 3 -82 0 0 0x20   wl0.1_bsd_sta_select_policy=30 -82 0 0 0 1 1 0 0 0 0x20
```
`bsd` is the closed AiMesh/roaming-assist daemon (RSSI-threshold steering at `-82` dBm). The
open `netctl steer` path replaces it with explicit, on-demand 802.11v BTM — webui can decide
*when* and *where* to steer from its own logic instead of the daemon's policy strings.

## Safety / footprint

All tests were pure-runtime on a disposable `wl2` SAE BSS (no nvram, no `restart_wireless`).
`set bss_transition 1` was applied to user net `wl2.1` during probing and **reverted to 0**;
it is a benign capability flag (no outage, auto-reverts on reboot). The 4 user nets stayed
`isup=1`; the disposable BSS + hostapd were `kill -9`'d and `interface_remove`'d after.
