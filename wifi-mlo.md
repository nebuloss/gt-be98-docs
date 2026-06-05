# Wi-Fi 7 MLO (Multi-Link Operation) on the GT-BE98 — structure & controllability map

> **RE 2026-06-05** (pure-runtime, read-only — the main MLO net was never disrupted).
> Maps how the BE98 models 802.11be **MLO** across its 4 radios, what nvram/driver knobs
> drive it, and — honestly — **what webui can and cannot control** without a
> `restart_wireless`.

## TL;DR

- The **main network is one MLD** spanning all 4 radio links; every **guest/SDN net is
  single-link** (not MLO). [V]
- MLO is **driver-internal, configured from nvram at `wlconf` init** — there is **no runtime
  `wl mlo`/`mld` iovar** (all return `Unsupported`). hostapd 2.10 here does **not** manage
  MLO either (no `mld_ap` in the confs; it only sets `ieee80211be=1`). [V]
- Therefore webui **cannot create or regroup MLO links at runtime**. Changing MLO membership
  = nvram (`apm*_mlo` / `wlX.Y_bss_mlo_mode`) **+ `restart_wireless`** (a full driver rebuild,
  the all-radio blip). Guest-net MLO is *structurally* expressible the same way but is
  **UNVERIFIED** (would need `restart_wireless`, which collides with the live nets — not run). [P]

## The MLD structure (the main net) [V]

The main SSID lives on the **primary BSS of every radio** (`wlX.0`), all four with
`bss_mlo_mode=1` → grouped into **one AP MLD**. Each radio contributes one **link**; the
per-radio "MLD Address" reported by `wl status` is that link's address (= the radio MAC):

| radio | band | link / MLD addr | `wlX_bss_mlo_mode` | `wlX_11be` | `nband_type` |
|---|---|---|---|---|---|
| `wl3` | 2.4 GHz | `60:CF:84:38:87:B0` | 1 | 1 | 0 |
| `wl0` | 5 GHz low | `60:CF:84:38:87:B4` | 1 | 1 | 2 |
| `wl1` | 5 GHz high | `60:CF:84:38:87:B8` | 1 | 1 | 3 |
| `wl2` | 6 GHz | `60:CF:84:38:87:BC` | 1 | 1 | 4 |

`wl -i <radio> status` →  `MLO: MLD Address: <addr>` + `EHT Capable:`. `wl -i <radio> eht`
→ `1`. (`nband_type`: 0=2.4G, 2=5G-low, 3=5G-high, 4=6G.)

## The nvram model

### `apm*` = the main-AP / MLO profile registry (distinct from `apg*` = guest/SDN)

```
apm1_ssid=BA9C09E1399AB24D897653DCD444FB5B   apm1_mlo=1   apm1_11be=1
apm1_dut_list=<*>127>                         # mask 127 = ALL radios/bands
apm1_security=<3>psk2sae>aes+gcmp256>…<13>…<16>sae>…<96>sae>aes+gcmp256>…  # WPA2/WPA3 per band, SAE on 6G
apm2_ssid=MyPrivateNetwork  apm2_mlo=0  apm2_dut_list=<*>1>   # 2.4G-only, NOT MLO
apm3..apm10  = disabled/empty
```

- **`apm1_mlo=1`** is *the* MLO main net: one SSID, `dut_list` mask `127` (all bands),
  MLO on. **`apm2_mlo=0`** shows a non-MLO single-band main-profile net for contrast.
- `apm*` mirrors the `apg*` field shape (`_ssid/_security/_dut_list/_enable/_mlo/_11be`) but
  is the **main/CAP** profile family; `apg*` is the guest/SDN family (see `netctl-verified.md`).

### Per-BSS MLO flag — `wlX.Y_bss_mlo_mode`

```
wl0_bss_mlo_mode=1  wl1_bss_mlo_mode=1  wl2_bss_mlo_mode=1  wl3_bss_mlo_mode=1   # 4 primaries = the MLD
wl3.1_bss_mlo_mode=1                                                            # a 2.4G backhaul slot, also MLO
wl0.1/wl0.2/wl0.3 = wl1.1/2/3 = wl2.1 = wl3.2..wl3.6  -> bss_mlo_mode=0          # ALL guests: NOT MLO
```

This is the definitive per-interface MLO switch: **1 on the radio primaries (main net), 0 on
every SDN/guest BSS**. The SDN nets (`apg1..5` = DEV-SCEP/test/Pagoa/Ramondia) all have empty
`apgX_mlo` and their BSSes are `bss_mlo_mode=0`. So **guest nets are single-link by design.** [V]

### A second, currently-unused MLD surface

```
mld_enable=0     mld0_ifnames=   mld1_ifnames=   mld2_ifnames=
mlo_cap_mssid_subunit=4   mlo_dwb_mssid_subunit=4   mlo_map=   mlo_aap1=   mlo_aap2=
```

`mld_enable`/`mldX_ifnames` is an **explicit ifname-grouping** MLD config that is **empty/off**
here — the active MLO is driven entirely by `apm*_mlo` + per-BSS `bss_mlo_mode`, not by this.
`mlo_cap_mssid_subunit=4` / `mlo_dwb_mssid_subunit=4` reserve **mssid subunit 4** for the
CAP/DWB (dedicated-backhaul) MLO links — a hint that MLO is bound to specific BSS subunits in
this firmware, not arbitrary guest subunits. (`aap`/`map` are AiMesh multi-AP MLO fields,
unused on a standalone AP.)

## Runtime controllability — what the `wl` driver exposes [V]

```
wl -i wl2 mlo | mld | mlo_config | mld_config | mlo_mode | mlo_link | mlo_links
   | mlo_status | mlo_enab | mld_addr | mlo_actframe | ml_assoc | mlc_status   -> ALL "Unsupported"
wl -i wl2 eht        -> 1            # EHT/11be IS a live iovar
wl mlo / wl mld      -> Unsupported  # no top-level MLO command
```

So **MLO has no runtime `wl` control verb** on this impl105 build. The driver builds the MLD
from nvram at init (`wlconf`); `wl` only exposes EHT-rate/PHY control, not link grouping.
hostapd's role is limited to `ieee80211be=1` per BSS (hostapd 2.10 predates upstream MLO).

## Answers to the brief's questions

1. **How is multi-link modeled?** One AP MLD = the 4 radio-primary BSSes (`wlX.0`,
   `bss_mlo_mode=1`), one per band, advertised under `apm1` (`apm1_mlo=1`, all-band SSID).
   Each radio = one link; `wl status` shows the per-link/MLD address. [V]
2. **Can a guest net be MLO?** Not as configured — every SDN/guest BSS is `bss_mlo_mode=0`
   and `apgX_mlo` is empty; `mlo_*_mssid_subunit=4` suggests MLO is bound to the CAP/DWB
   subunit, not guest subunits. Making a guest MLO would mean setting `bss_mlo_mode=1` on
   its per-radio BSSes (+ `apgX_mlo`) and a `restart_wireless` — **structurally plausible but
   UNVERIFIED** (not tested: `restart_wireless` churns all BSSes and would collide with the
   live nets). [P]
3. **Can webui create/group MLO links directly, or does it need `restart_wireless`?**
   **It needs `restart_wireless`.** There is no runtime `wl mlo` primitive; MLO grouping is a
   `wlconf`-time, nvram-driven operation. This is the honest limit: unlike add/remove of a
   *single-link* BSS (which is pure-runtime via `wl interface_create`), changing MLO link
   membership is a structural (driver-rebuild) change. [V]

## Method / safety

All recon was **read-only** (`wl ... status`/iovar probes, `nvram show`) — nothing created,
no `restart_wireless`, the main MLO net and the 4 user nets stayed up throughout. RE refs:
`wlconf` (reads `apm*`/`wlX.Y_bss_mlo_mode` at init), `wlioctl_defs.h` (EHT iovars), and the
`apm_*` family in the ASUS nvram defaults.
