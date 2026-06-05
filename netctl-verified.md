# netctl — verified open net-create / net-delete (the mtlancfg bypass that works)

> **VERIFIED LIVE 2026-06-04** on the GT-BE98 (sw_mode=3, standalone AP). This
> supersedes the pessimistic conclusion of [sdn_investigation.md](sdn_investigation.md)
> §5/§8 ("webui can't own VLAN provisioning, allocation only via the GUI"): that work
> predated the discovery of **`rc sync_apgx_to_wlunit`**, which IS the open equivalent of
> the GUI's slot-allocation step. With it, a brand-new WiFi VLAN can be created entirely
> from nvram + CLI, no GUI, no firmware patch, fully reversible.

## The verified recipe (create a WiFi VLAN)

Implemented in [`src/netctl/netctl.sh`](src/netctl/netctl.sh) as `net-create`. Steps:

1. **Clone a working net's apg field-set** into a free `apg<N>` slot (here apg5).
   Cloned from apg3/Pagoa — the fields that matter:
   ```
   apg5_enable=1  apg5_ssid=<name>  apg5_hide_ssid=0  apg5_disabled=0
   apg5_macmode=disabled  apg5_bw_limit=<0>>  apg5_mlo=
   apg5_dut_list=<60:CF:84:38:87:B0>1>          # <own-CAP-MAC>1>  (NOT a band mask)
   apg5_security=<3>pskpsk2>aes>PSK>3<13>pskpsk2>aes>PSK>3<16>sae>aes>PSK>3<96>sae>aes>PSK>3
   ```
   Band codes in the security blob: **3=2.4G, 13=5G-low, 16=5G-high, 96=6G**
   (sae=WPA3 on 6G is mandatory). An all-band single entry `<127>...>N` (used by
   DEV-SCEP/Ramondia) is the enterprise/empty-PSK form.
2. **Append one entry to each registry list** (next index = max+1):
   ```
   sdn_rl    += <6>Customized>1>4>4>5>0>0>0>0>0>0>0>0>0>0>0>0>0>WEB>0>0>0
                 # <sdn_idx>Customized>en>vlan_idx>subnet_idx>apg_idx>...>WEB>0>0>0
   vlan_rl   += <4>40>0>                          # <vlan_idx>VID>port_isolation>
   subnet_rl += <4>br40>192.168.40.1>255.255.255.0>0>192.168.40.2>192.168.40.254>86400>>,>>0>>0>0>>1000>2000>,,>0>1>
                 # <subnet_idx>br_ifname>gw>mask>dhcp_en>min>max>lease>domain>dns>wins>...
   ```
3. **`rc sync_apgx_to_wlunit`** — allocates a real `wlX.Y` BSS slot for the new SDN
   entry and writes it to the persistent allocation file (see "Reversibility").
4. **`service "restart_wireless;restart_sdn <sdn_idx>"`** — instantiates the BSS and
   builds the bridge.

### Observed result (apg5 / VID40 / "netctl-t40")
```
wl3.6  ssid=netctl-t40  isup=1            # the BSS beacons
br40   members: wl0.40 wl1.40 wl2.40 wl3.40 wl3.6
                # wl3.6 = the beaconing BSS slot; wlX.40 = silent front-haul VLAN ifaces
apg_ifnames_used.json += {"sdn_idx":"6","sdn_vid":"40","sdn_band":[{"band_idx":"1","wl_prefix":"wl3.6"}]}
```

## Verified facts

- **`rc sync_apgx_to_wlunit` allocates slots for nvram-defined nets.** [V]
  The old "allocation only happens via the full GUI payload" is FALSE — `rc` exposes
  the same routine. It preserves existing nets' allocations and adds the new one.
- **Kernel bridge name = `br<VID>`, always.** [V] The `br_ifname` field in `subnet_rl`
  (live values `br54`/`br55`/`br50`) is an opaque internal id, NOT the Linux bridge name.
  VID40 produced `br40` regardless. (`br50`==VID50 is a coincidence.)
- **Multi-band is driven by the `apg<N>_dut_list` band mask — SOLVED 2026-06-05.** [V]
  The band count has *nothing* to do with the security blob; it is the `<MAC|*>MASK>`
  mask field of `apg<N>_dut_list`. The old recipe hardcoded mask `1` (2.4G only), which
  is why new nets came up single-band. Setting the mask to the OR of the desired radios'
  band bits makes `sync_apgx_to_wlunit` allocate all of them. See **Band-mask encoding**
  below; `netctl net-create --bands` now exposes it (default `2.4,5` = mask 13 = 3 bands).
- **net-delete is the exact inverse and is clean.** [V] Drop the 3 list entries +
  `apg<N>_enable=0` + `rc sync_apgx_to_wlunit` + restart → BSS/bridge gone, and the
  allocation json returns **byte-identical** to before. No GUI, no corruption.

## Band-mask encoding — multi-band new-net allocation (TASK 6a, VERIFIED 2026-06-05)

`apg<N>_dut_list` has the form `<MAC|*>MASK>`. `MASK` is the **OR of the per-radio band
bits** that `sync_apgx_to_wlunit` allocates into `apg_ifnames_used.json` (the `band_idx`
field is the *same* bit). Mapped live by `sync`-only probes (allocation-only, **zero
outage** — no `restart_wireless`), then confirmed beaconing end-to-end:

| mask bit | `band_idx` | radio | band | netctl `--bands` token |
|---:|---:|---|---|---|
| 1  | 1  | wl3 | 2.4 GHz   | `2.4` |
| 2  | —  | (none) | reserved/unused (allocates nothing) | — |
| 4  | 4  | wl0 | 5 GHz low | `5l` (or `5`) |
| 8  | 8  | wl1 | 5 GHz high| `5h` (or `5`) |
| 16 | 16 | wl2 | 6 GHz (SAE)| `6` |

So `MASK = Σ band_idx`. Useful values: **13** = `2.4,5` (= 1+4+8, the same 3-band shape
as the live user nets), **29** = `all` (= +6G), **16** = 6G-only, **1** = 2.4-only.

Live results [V]:
- `--bands all` (mask 29) on apg5/VID40 → **all four** beacon in br40 with distinct BSSIDs:
  `wl3.6` (2.4G) `wl0.3` (5GL) `wl1.3` (5GH) **`wl2.1` (6G)** — 6 GHz works too.
- `--bands 2.4,5` (mask 13) → `wl3.6 + wl0.3 + wl1.3` (matches DEV-SCEP/Ramondia).
- Allocation map `band_idx`s equal the mask bits exactly; probing masks 13/29/16/2/31
  showed bit 2 allocates nothing and 31≡29 (bit 2 ignored).
- `net-delete` after a 4-band create restored `apg_ifnames_used.json` **byte-identical**
  (md5 match) — the inverse is clean for multi-band too.
- **CAP-MAC normalization:** `sync`/`restart_wireless` rewrite an explicit CAP MAC in
  `dut_list` to the wildcard `*` (all three live user nets sit at `<*>...>`). `net-create`
  now writes `<*>MASK>` directly. [V]

The full 4-band security blob (`<3>..<13>..<16>..<96>sae..`) is written regardless of the
selected bands; extra per-band security entries with no allocated radio are harmless [V].
6 GHz mandates SAE — the `<96>sae>` entry covers it.

## Reversibility (how the live tests stayed safe)

`rc sync_apgx_to_wlunit` runs `_sync_apgx_to_wlunit(json2jffs=1, …)` — confirmed by
disassembly of `/usr/sbin/cfg_server` (the public wrapper does `mov r0,#1` then tail-calls
the internal fn). So it **persists** the allocation to `/jffs/.sys/cfg_mnt/apg_ifnames_used.json`.
A reboot alone does NOT revert that file. Safe-test protocol (used here):
- **never `nvram commit`** during the test → a reboot reverts the running nvram to the
  committed-clean config;
- **back up `/jffs/.sys/cfg_mnt`** before the test and restore on revert (or let the
  dead-man restore it + reboot);
- **dead-man reboot** (`netctl deadman`) self-recovers a lost session.
- The earlier "persistent damage" of [sdn_investigation.md](sdn_investigation.md) §8 came
  from a *partial* `apply.cgi` payload, not from `sync_apgx_to_wlunit`, which is the
  complete/correct allocator.

## Lightest apply for a new net (P0.2) — `restart_wireless` is the floor [V]

Ladder-tested live (each from an nvram-set + `rc sync_apgx_to_wlunit` state, on apg5/VID40):

| apply command | new BSS (wl3.6) | bridge br40 |
|---|---|---|
| `service "restart_sdn 6"` alone | ✗ not up | ✗ missing |
| `service "restart_apg;restart_sdn 6"` | ✗ not up | ✗ missing |
| `service "restart_wireless;restart_sdn 6"` | ✓ isup=1 | ✓ exists |

`restart_sdn` only runs `handle_sdn_feature` (firewall/routing/dnsmasq/vpn — the **L3**
layer; `rc/sdn.c`). `restart_apg`/`apg_start` doesn't create a new driver vif either.
Instantiating a **new** BSS slot needs the driver rebuilt → **`restart_wireless`** (a
brief all-radio blip; it takes no arguments, `rc.c:4370`). There is **no per-radio
`restart_wireless_unit` on stock firmware** (it only exists in the patched-firmware
scoped-apply path — see [wifi-apply-no-outage.md](wifi-apply-no-outage.md)). So: net
**create/delete** = one `restart_wireless`; net **edit** = the no-outage primitives below
(no restart at all).

## No-outage runtime primitives (P0.4) — corrected effective methods [V]

Live-tested on the disposable BSS wl3.6 while the 3 user nets stayed UP throughout.
**A managed apg BSS is owned by its radio's hostapd**, so the `wl`-level pokes that work
on driver-owned ifaces are silently overridden here:

| Goal | ❌ ineffective (hostapd re-asserts) | ✅ effective, zero outage |
|---|---|---|
| Change SSID | `wl -i <bss> ssid X` (get_config keeps old) | `hostapd_cli -i <bss> set ssid X` + `update_beacon` |
| Disable a BSS | `wl -i <bss> bss down` (reverted <2s, isup stays 1) | `hostapd_cli -i <bss> disable` (state→DISABLED) |
| Enable a BSS | — | `hostapd_cli -i <bss> enable` (state→ENABLED, isup→1) |
| Hide/unhide | (`wl closed` holds the flag) | `wl closed 1\|0` + `hostapd_cli set ignore_broadcast_ssid 1\|0` + `update_beacon` |
| Move BSS VLAN | — | `brctl delif <oldbr> <bss>` ; `brctl addif <newbr> <bss>` (holds at t+2s) |

These are wired into netctl as `ssid`/`hide`/`show`/`bss`/`bridge` and the per-apg
`net-edit <apg> ssid <name>` (renames every live BSS of the apg + persists nvram).
Two gotchas found & fixed in the tool:
- existence guard must use `ip link show <bss>` (or the hostapd socket), **not**
  `wl bssid` — the latter errors on a *disabled* BSS, blocking `bss up`.
- `command -v rc` spuriously fails on this busybox though `rc` runs; netctl scans PATH.

Caveat (unchanged): while `cfg_server`/`mtlancfg` is live it regenerates
`/tmp/wlX_hapd.conf` and may re-assert these on its triggers — runtime edits are durable
only across the period until the next `restart_wireless`. The durable equivalent is the
nvram path (`net-create`/`net-edit` set nvram too; `netctl commit` persists). A
**no-outage PSK change has no reliable path** while cfg_server owns the conf (hostapd has
no `reconfigure` verb) → use `net-delete` + `net-create`.

## RE references
- `rc` dispatch: `rc.c:540` → `sync_apgx_to_wlunit(NULL)`.
- header: `cfg_mnt/cfg_mtlan.h` — `_sync_apgx_to_wlunit(int json2jffs, json_object*)`,
  `sync_apg_ifnames_to_jffs()`, `get_apg_ifnames_used_filename()`.
- `subnet_rl` parse + `SUBNET_T`: `shared/mtlan_utils.c` / `shared/mtlan_utils.h`.
- `restart_sdn <idx>`: `services.c` → `handle_sdn_feature(atoi(idx), SDN_FEATURE_ALL, …)`.
- allocation state: `/jffs/.sys/cfg_mnt/apg_ifnames_used.json` (perms 000).
