# webui owns WiFi directly — the verified zero-orchestration recipe

> **VERIFIED LIVE 2026-06-05** on the GT-BE98 (BCM6813, impl105 `wl` driver, sw_mode=3 AP).
> A complete WiFi network — including a **secured WPA2** one — can be created, configured,
> bridged, and destroyed **entirely from `wl` + `hostapd` + `brctl`**, with **zero** ASUS
> orchestration: no `cfg_server`, no `mtlancfg`, no `rc`, no `restart_wireless`, no
> `sync_apgx_to_wlunit`, no `wlconf`, and (at runtime) no `nvram`. This is the proof that
> webui-go can fully own the WiFi control plane.

## The layer model (the key mental model)

| Layer | What it is | How webui touches it |
|---|---|---|
| **Radio / PHY** | the RF core: powered, tuned to a channel, transmitting | already up after boot; channel via `netctl chanspec` (rare) — **untouched for add/remove net** |
| **BSS (a WiFi/SSID)** | one AP; the Linux netdev `wlX.Y`; a driver "bsscfg" slot | **create / configure / up / bridge / destroy — all `wl`+`hostapd`+`brctl`** |

Adding a network does **not** touch radio emission. It adds a **BSS** on an already-running
radio. `wlX.Y` *is* bsscfg index `Y`. Slots are pre-created at boot by `wlconf` from the
`wlX_vifs` nvram list — **but** new slots can also be created at runtime (below), so the
boot budget is not a ceiling.

## The verified primitives

Radio→band: `wl3`=2.4 GHz, `wl0`/`wl1`=5 GHz, `wl2`=6 GHz. Beacon proof in every test =
the per-BSS `txbcnfrm` (transmitted-beacon) counter incrementing.

### 1. Create a BSS interface — two equivalent ways

**(a) Use a free pre-created slot** (e.g. `wl3.1`/`wl3.4` are the unused mesh-backhaul
slots on a standalone AP — `bss=down`, empty SSID, netdev already present). [V]

**(b) Create a brand-new vif at runtime** — `wl interface_create` (no `wlconf`): [V]
```
wl -i wl3 interface_create ap        # -> "ifname: wl3.7 bsscfgidx: 7 mac_addr BA:CF:..."
#   type is a STRING keyword: "ap" or "sta" (NOT a number — numeric prints usage).
#   optional: -m <MAC> -b <BSSID> -f <if_index>.  AP type is required for a beaconing BSS.
```
The new netdev `wl3.7` appears immediately, AP-type, with an auto-assigned BSSID.
Per-radio max is finite ("Not Enough Resources" when the radio's BSS table is full).

### 2. Configure + bring up

**Open network** (no auth) — `wl` alone, no hostapd needed: [V]
```
wl -i wl3.7 ssid "MyOpenNet"
wl -i wl3.7 bss up                   # -> isup=1, bss=up, BSSID assigned, txbcnfrm climbs
```

**Secured network (WPA2/WPA3)** — webui writes its own hostapd conf and launches it: [V]
```
cat > /tmp/wl3.7.conf <<EOF
driver=nl80211
ctrl_interface=/var/run/hostapd
interface=wl3.7
bridge=br40
ssid=MySecureNet
hw_mode=g           # g=2.4G(wl3), a=5G(wl0/wl1)/6G(wl2)
channel=1           # MATCH the radio's current channel (no PHY retune, no blip)
country_code=E0
auth_algs=1
wpa=2               # 2=WPA2; for WPA3: wpa_key_mgmt=SAE, ieee80211w=2
wpa_key_mgmt=WPA-PSK
wpa_pairwise=CCMP
wpa_passphrase=secret123
EOF
hostapd -B /tmp/wl3.7.conf           # -> state=ENABLED, wpa_auth=0x80 (WPA2-PSK), beaconing
```
A **separate per-BSS hostapd coexists with the radio's primary hostapd** — verified live, the
other BSSes on `wl3` (Pagoa/DEV-SCEP/test) never blipped. Match the radio's current channel
so hostapd does no PHY retune.

### 3. Bridge / VLAN

```
brctl addif br40 wl3.7               # holds; eth side via eth0.40.. (8021q) as usual
```
`brctl` moves/holds a `wl*` BSS (verified). For an isolated net make a fresh bridge.

### 4. Destroy

```
# open net:   wl -i wl3.7 bss down ; wl -i wl3.7 interface_remove
# secured:    kill <that hostapd pid> ; wl -i wl3.7 bss down ; brctl delif br40 wl3.7 ; wl -i wl3.7 interface_remove
```
`wl -i wl3.7 interface_remove` deletes the runtime-created vif cleanly (netdev gone, slot
freed). For a *pre-created* slot, just `bss down` + clear SSID (don't remove it).

## End-to-end, what webui calls (and what it never calls)

```
create:  wl interface_create ap  ->  [wl ssid | write hapd.conf + hostapd -B]  ->  brctl addif
edit:    hostapd_cli set ssid + update_beacon | hostapd_cli disable/enable | brctl delif/addif
delete:  kill hostapd ; wl bss down ; brctl delif ; wl interface_remove
status:  wl assoclist / hostapd_cli all_sta / wl scanresults  (netctl clients/scan/events)
```
**Never needed:** `cfg_server`, `mtlancfg`, `rc`, `restart_wireless`, `sync_apgx_to_wlunit`,
`wlconf`. The only stock pieces left in the loop are the **closed `wl` driver** (called via
ioctl; reads reimplementable in Go like `owl`) and **hostapd** (open upstream + vendor
patches, launched directly). Both are direct, not orchestrators.

## nvram = persistence only

At runtime webui owns everything above. nvram matters only so the config **survives a
reboot**: at cold boot the closed `wlconf` reads `wlX_*` / `wlX_vifs` / `lan_ifnames` to
recreate the radios + the pre-created vif slots. So the model is:
- **runtime**: direct `wl`/`hostapd`/`brctl` (this doc) — instant, no orchestration;
- **persistence**: write the equivalent nvram so a reboot rebuilds the same set. webui can
  also pre-provision a generous `wlX_vifs` pool once (one `restart_wireless`) and then never
  call `rc` again, or just re-create vifs at boot from its own init.

## Implication for the cfg_server retirement

This removes the last caveat in [plans/patch-0028-retire-cfg_server.md](plans/patch-0028-retire-cfg_server.md):
webui does not even need the `rc sync_apgx_to_wlunit` allocator if it drives `wl
interface_create` directly — it owns the whole chain. cfg_server, mtlancfg, and the rc apply
path are all replaceable by direct calls.

## Reference implementation

`src/netctl/netctl.sh` exposes these primitives as `bss-create` / `bss-up` / `bss-destroy`
(open BSS) — a working reference for the webui-go port. See the README.
