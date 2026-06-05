# Open status-JSON publisher — `netctl status-json` (cfg_server replacement)

> **VERIFIED LIVE 2026-06-05.** Reproduces cfg_server's `/tmp/*.json` status files from open
> tools (`wl` / `hostapd_cli` / `brctl` / `/proc/net/arp` / sysfs) so webui can drop the
> cfg_server dependency — the last item blocking
> [patch-0028 (retire cfg_server)](plans/patch-0028-retire-cfg_server.md). Wired into
> `netctl` as **`status-json`**.

## What cfg_server publishes vs. what `netctl` reproduces

| file | shape | netctl source | status |
|---|---|---|---|
| `aplist.json` | `{"0":{"ap2g","ap5g","ap5g1","ap6g","ap6g1","apdwb"}}` | per-radio MLD/link MAC (`wl status`) | **byte-identical** [V] |
| `clientlist.json` | `{"<CAP>":{"wired_mac":{mac:{ip}}, "<band>":{mac:{rssi}}}}` | fdb (brctl) + arp + `wl assoclist` | **shape-identical** [V] |
| `wiredclientlist.json` | `{"<CAP>":{mac:{ts[,sdn_idx]}}}` | fdb (brctl) + VID→sdn map | **shape-identical, sdn_idx matches** [V] |
| `allwclientlist.json` | `{}` / `{"<CAP>":{mac:{...}}}` | `wl assoclist` per BSS | **byte-identical (`{}`)** [V] |

`CAP` = the router's own MAC (`nvram get lan_hwaddr` = `60:CF:84:38:87:B0`).

## Verified diff against live cfg_server [V]

```
aplist        MINE == LIVE  (byte-identical)
  {"0":{"ap2g":"60:CF:84:38:87:B0","ap5g":"…B4","ap5g1":"…B8","ap6g":"…BC","ap6g1":"","apdwb":""}}
allwclientlist  MINE == LIVE == {}   (no wireless clients associated)
clientlist / wiredclientlist  shape-identical; the per-VLAN sdn_idx values MATCH cfg_server:
  94:2A:6F:F6:F3:7D -> sdn_idx 5 ,  3C:E9:F7:5F:42:1D -> sdn_idx 4 ,  9C:53:22:3C:EB:08 -> sdn_idx 4
```

Exact *membership* of the wired list is timing- and policy-dependent (the fdb ages entries;
cfg_server applies its own include filter for infra MACs), so a byte-for-byte client set is
not expected — the **schema and the VLAN attribution are the contract**, and both match.

## How the data is derived (the open recipe)

- **`aplist`** — `ap2g/ap5g/ap5g1/ap6g` = the per-radio MAC, read from
  `wl -i wl{3,0,1,2} status` → `MLO: MLD Address:`. (`ap6g1`/`apdwb` empty on this 4-radio AP.)
- **wired client** = an fdb entry (`brctl showmacs <br>`, `is_local=no`) whose bridge **port
  is an Ethernet iface**. Port→iface is resolved from `/sys/class/net/<br>/brif/<if>/port_no`
  (hex, e.g. `0x9`; compared decimal to the `brctl showmacs` port column). `wl*` ports are
  skipped (those fdb macs are the AP's own per-radio BSS macs, not clients).
- **IP** — looked up by MAC in `/proc/net/arp` (empty string when the client has no live ARP
  entry, exactly like cfg_server).
- **sdn_idx** — the bridge's `VID` (`br<VID>`) → `vlan_rl` (VID→vlan_idx) → `sdn_rl`
  (vlan_idx→sdn_idx). `br0` clients have no sdn_idx (main LAN).
- **dedupe** — the Ethernet ports are a **VLAN trunk**, so a tagged client's MAC appears in
  both `br0` and its `br<VID>`. `netctl` dedupes by MAC, upgrading to the non-empty IP and the
  VLAN sdn_idx (so a VLAN client is attributed to its SDN, not to br0) — matching cfg_server's
  attribution.
- **wireless client** = `wl -i <bss> assoclist` MACs; band from the radio
  (`wl3`=2G `wl0`=5G `wl1`=5G1 `wl2`=6G); RSSI from `wl -i <bss> rssi <mac>`. Grouped under a
  band key in `clientlist` and listed in `allwclientlist` (both `{}`-empty when no STA is
  associated, as now).

## Usage

```
netctl status-json [aplist|clientlist|wiredclientlist|allwclientlist|all] [outfile|outdir]
```
- no args → emits all four to stdout (labelled);
- `status-json clientlist` → just that object;
- `status-json all /tmp` → writes `/tmp/{aplist,clientlist,wiredclientlist,allwclientlist}.json`
  (drop-in for the cfg_server files; webui can publish these directly).

All output validated as well-formed JSON (`python3 -m json.tool`). Read-only — no nvram, no
restart, safe to run on the live AP.
