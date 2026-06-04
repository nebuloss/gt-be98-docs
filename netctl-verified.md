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
- **A new net is allocated a SINGLE band (2.4G, on wl3) by `sync_apgx_to_wlunit`,** even
  with a 4-band security blob. [V] Existing multi-band nets (DEV-SCEP, Ramondia) keep
  their 3-band allocation. Getting multi-band on a *new* net from CLI is still open
  (the GUI's flow allocates more) — tracked for P0/P2.
- **net-delete is the exact inverse and is clean.** [V] Drop the 3 list entries +
  `apg<N>_enable=0` + `rc sync_apgx_to_wlunit` + restart → BSS/bridge gone, and the
  allocation json returns **byte-identical** to before. No GUI, no corruption.

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

## RE references
- `rc` dispatch: `rc.c:540` → `sync_apgx_to_wlunit(NULL)`.
- header: `cfg_mnt/cfg_mtlan.h` — `_sync_apgx_to_wlunit(int json2jffs, json_object*)`,
  `sync_apg_ifnames_to_jffs()`, `get_apg_ifnames_used_filename()`.
- `subnet_rl` parse + `SUBNET_T`: `shared/mtlan_utils.c` / `shared/mtlan_utils.h`.
- `restart_sdn <idx>`: `services.c` → `handle_sdn_feature(atoi(idx), SDN_FEATURE_ALL, …)`.
- allocation state: `/jffs/.sys/cfg_mnt/apg_ifnames_used.json` (perms 000).
