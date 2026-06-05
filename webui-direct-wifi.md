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

## Security recipes — verified direct (WPA2 / WPA3-SAE / transition) [V]

> **VERIFIED LIVE 2026-06-05** on a disposable 6 GHz vif (`wl2.2`, runtime-created), a
> separate per-BSS `hostapd -B` coexisting with the radio's primary hostapd — siblings
> (`wl2.1`/test) never blipped. The driver-level AKM is read back with `wl -i <bss> wpa_auth`
> (definitive proof the BSS advertises that key-mgmt), and beaconing with `txbcnfrm`.

The create chain is identical for every security mode — only the hostapd conf differs:
`wl interface_create ap` → write conf → `hostapd -B -t -f log conf` → (optional `brctl addif`).
Match `channel=` to the radio's current channel so hostapd does **no PHY retune** (6 GHz:
`hw_mode=a channel=<N>` where the radio's `6gN/160` → `channel=N`; e.g. `6g1` → `channel=1`,
RF freq 5955 MHz = 5950 + 5·N). This build's hostapd is **v2.10**; it accepts `ieee80211be=1`
but **rejects `ieee80211ax`** (omit it — HE/EHT are negotiated by the driver regardless).

**`wl wpa_auth` AKM bit decode (observed live):**

| `wpa_auth` | meaning |
|---|---|
| `0x80` | WPA2-PSK |
| `0x40000` | SAE (WPA3-Personal) |
| `0x40080` | WPA2-PSK **+** SAE (WPA2/WPA3 transition) |
| `0x0` | open / not-yet-applied (or hostapd failed to bind — see gotchas) |

`wsec=68` (`0x44` = CCMP `0x04` + MFP/group-mgmt `0x40`) accompanies an MFP-protected BSS.

### WPA3-SAE (WPA3-Personal) — the 6 GHz mode [V]
```
wpa=2
wpa_key_mgmt=SAE
rsn_pairwise=CCMP
sae_password=re-saetest123          # or wpa_passphrase=...
ieee80211w=2                        # MFP required for SAE
sae_require_mfp=1
sae_pwe=2                           # 0=loop 1=H2E 2=both (6 GHz wants H2E)
```
Result: `state=ENABLED`, `wl wpa_auth=0x40000 SAE`, `wsec=68`, `freq=5955` (6g ch1),
`txbcnfrm` +10/s. `hostapd_cli -i <bss> status` reports `key_mgmt[0]=SAE`.

### WPA2/WPA3 transition (mixed) [V]
```
wpa=2
wpa_key_mgmt=WPA-PSK SAE
rsn_pairwise=CCMP
wpa_passphrase=re-transit123
ieee80211w=1                        # 1=optional so legacy WPA2-PSK clients still join
sae_pwe=2
```
Result: `wl wpa_auth=0x40080` (both AKMs in the RSN IE), beaconing. Verified on **5 GHz
(`wl1`)** and **6 GHz (`wl2`)**.

### Notable finding — this driver does NOT enforce the 6 GHz "SAE-only" rule [V]
The 802.11 spec forbids WPA2-PSK on 6 GHz (SAE+MFP only). On this BCM6813/impl105 build,
hostapd **accepts** `WPA-PSK SAE` on a 6 GHz vif and the driver reports `wpa_auth=0x40080`
(WPA2-PSK present) — it reached `AP-ENABLED` and beaconed. So the *authenticator* will offer
WPA2-PSK on 6 GHz; spec-compliant 6 GHz **clients** will still refuse the PSK AKM and use SAE.
For correctness, keep 6 GHz on pure `SAE` (`netctl net-create` already writes `<96>sae>` for
the 6 GHz band). WPA2-only (`wpa_key_mgmt=WPA-PSK`, no SAE) is for 2.4/5 GHz.

### On-box client testing is NOT possible — authenticator-side is the proof [V]
The router ships **`wpa_supplicant v0.6.10`** whose only drivers are `wired`/`roboswitch`
(the WAN 802.1X supplicant) — **no `nl80211`, no SAE/WPA2 WiFi station support**. A full
over-the-air 4-way/SAE handshake cannot be driven on-box (and an on-box STA vif shares its
radio's channel, so it can't independently tune to a test AP either). The verified proof is
therefore the **authenticator side**: `wl wpa_auth` AKM + `hostapd_cli status key_mgmt` +
beaconing. A real client (phone/laptop) is the end-to-end check.

### Gotchas learned the hard way
- **`kill` (SIGTERM) a per-BSS hostapd may not release the iface promptly**; the next
  `hostapd -B` on the same vif then fails with `Unable to setup interface` and the BSS shows
  `wpa_auth=0x0`. Use **`kill -9`**, `rm` the conf, and confirm no stray `hostapd .*re-` proc
  before relaunching. A leftover hostapd still owning `/var/run/hostapd/<bss>` is the cause.
- Always tear down in order: `kill -9 hostapd` → `wl bss down` → `brctl delif` → `interface_remove`.

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

## Channel control — change ONE radio's channel with ZERO outage (driver CSA) [V]

> **VERIFIED LIVE 2026-06-05** on wl2/6G. Changing a radio's operating channel does **not**
> require `restart_wireless` (the all-radio blip) and does **not** drop the BSSes.

Channel is a **radio/PHY** property (per-radio, not per-BSS), so all the BSSes on a radio
share it. The lightest viable runtime move is the **driver's own CSA iovar** — `wl csa`,
**not** `hostapd_cli chan_switch`:

```
wl -i <radio> csa <mode> <count> <chanspec>
#   mode:  0 = data allowed during the countdown (normal) ; 1 = after radar
#   count: beacons before the switch (~5 ≈ 0.5 s)
#   chanspec: full wl spec — csa infers the band from the channel# / `6g` prefix
wl -i wl2 csa 0 5 6g33/160            # 6 GHz: move to 6g33/160  (rc=0)
wl -i wl2 csa 0 5 6g5/80             # also changes BANDWIDTH (160 -> 80) live
```

Verified outage profile on wl2/6G (`6g1/160 → 6g33/160 → 6g5/80 → back`): every BSS on the
radio stays `isup=1` and **beacons never stop** — `wl -i <bss> counters | grep txbcnfrm`
climbed continuously across every move (no reset, no gap). **Single-radio, instant, no
all-radio blip.** All BSSes on the radio follow the new channel automatically (it's the
shared PHY). Associated clients that parse the CSA IE retune **without disassociating** [P]
(standard 802.11h CSA — the on-box `wpa_supplicant v0.6.10` can't drive an OTA STA to prove
the client side, see "On-box client testing is NOT possible" above; the verified facts are
the channel move + uninterrupted beaconing).

**Do NOT use `hostapd_cli -i <bss> chan_switch …`** — the hostapd CSA verb is **NON-VIABLE
on this build** (verified 2026-06-05). Use the **driver** `wl csa`.

CSA is **runtime-only**: it does not touch `wlX_chanspec` nvram, so a reboot reverts the
channel. For persistence, also `nvram set wlX_chanspec=<spec>` and commit (a cold boot then
brings the radio up on that channel). A bare `wl -i <radio> chanspec <spec>` (no CSA) is
**inert on an UP AP radio** — the BSS re-asserts the old channel.

netctl wraps this as **`netctl chanspec set <radio> <spec> --apply`** (driver CSA, zero
outage, default) with **`--restart`** as the heavy `restart_wireless` fallback and
**`chanspec auto <radio>`** for ACS (which has no CSA form → it re-inits via restart).

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
