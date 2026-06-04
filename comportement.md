# GT-BE98 router behaviour — verified reference

> Document based on **live** observation of the router (SSH `admin@10.0.0.8:2222`),
> ASUSWRT-Merlin / kernel 4.19.294 / BCM6813.
> When a point has not been confirmed empirically, it is marked "(inferred)".
>
> ⚠️ This document corrects several assumptions from the old docs
> ([nvram_schema.md](nvram_schema.md), [hostapd_schema.md](hostapd_schema.md)):
> the real model is **not** "hostapd drives interfaces per slot", but rather
> **Asus's SDN/Guest-Pro (apg) drives the bridging, hostapd only handles WPA**.
>
> ✅ **Update 2026-06-03:** we are now running on a **custom patched firmware**
> (`../gt-be98-firmware`). Consequences vs this doc: MAINFH (`wl3.1`/MyPrivateNetwork)
> is **removed at the source** (patch 0025, `nvram hapd_exclude_ifnames=wl3.1`) → the
> `ssid-suppressor`/`bridge-enforcer` watchdogs are **removed**; the Asus UI `:8443`
> is again **accessible** (DROP commented out); the webui can **flash** the firmware
> (`hnd-write`). infosvr is disabled by default (patch 0024).

---

## 1. Mental model in one sentence

The GT-BE98 is an **access point (bridge mode)**: it does not route and does not do
DHCP. An upstream gateway (here a **Ubiquiti**) handles routing + DHCP per
VLAN. The router's role is purely **L2**: take the frames from a Wi-Fi client,
drop them into the correct **VLAN bridge**, which goes out **802.1Q tagged** to the Ubiquiti.

```
Client Wi-Fi → BSS (wl3.2) → br30 → eth0.30 (tag VLAN 30) → trunk → Ubiquiti (DHCP/route)
```

---

## 2. Radios

| Interface | Band | nband | Default channel | Max width |
|---|---|---|---|---|
| `wl0` | 5 GHz-1 | 1 | 36  | 160 MHz |
| `wl1` | 5 GHz-2 | 1 | 108 | 80 MHz |
| `wl2` | 6 GHz   | 4 | 1   | 320 MHz |
| `wl3` | 2.4 GHz | 2 | 1   | 40 MHz |

**6 GHz (`wl2`) requires WPA3-SAE** (MFP required). See [hardware.md](hardware.md).

---

## 3. Interface and bridge model (the key point)

### The interfaces that actually exist

The **`wl` driver** creates the netdevs from the nvram (`wlX.Y_bss_enabled=1`),
**not** hostapd. The netdevs that are actually present:

| Netdev | Role | Bridge | BSSID |
|---|---|---|---|
| `wlX.0`  | Main BSS (hidden Asus SSID) | `br0` | base MAC `…:B0` |
| `wlX.1`, `wlX.3` | classic "Guest Network" slots | `br0` | distinct (`…:B1`, `…:B3`) |
| `wlX.<slot>` (e.g. `wl3.2`) | Guest-Pro BSS (apg) | `br<vlan>` **if** linked | distinct |
| `wlX.<VLAN>` (e.g. `wl3.20`, `wl3.30`) | SDN front-haul of the VLAN | `br<vlan>` | = base MAC |

> ⚠️ **Two naming schemes coexist and cause confusion**:
> - by **slot** (`wl3.2`) — the BSS that broadcasts the SSID, with its own BSSID;
> - by **VLAN** (`wl3.30`) — the front-haul interface of the VLAN bridge, base MAC.
>
> The SSID is carried by the **slot** BSS. The **driver** decides which bridge it
> lands in (see §5). `hostapd` thinks it drives `wl3.2` via `bridge=br30` but
> **this line is ignored**: it is the driver that manages bridge membership.

### Active bridges

| Bridge | VLAN | IP | Typical members |
|---|---|---|---|
| `br0`  | native (untagged) | `10.0.0.8/24` (admin LAN) | `eth0-3`, `wlX.0`, `wlX.1`, `wlX.3` |
| `br20` | 20 | none (Ubiquiti = gw) | `eth0-3.20`, `wlX.20`, linked slot |
| `br30` | 30 | none (Ubiquiti = gw) | `eth0-3.30`, `wlX.30`, `wl3.2` (NetB) |

- The VLAN bridges **have no IP**: the Ubiquiti addresses the clients.
- Ethernet uplinks: `eth0`/`eth1` have the link (carrier=1); `eth2`/`eth3` do not.
  Each port simultaneously carries `br0` (untagged) **and** `ethX.20`/`ethX.30` (tagged)
  → the port on the Ubiquiti side must be a **trunk** (untagged = admin LAN, tagged 20 & 30).

### ⚠️ `brctl` CANNOT move a Wi-Fi interface

```sh
brctl addif br30 wl3.2     # → "Operation not supported"
```
The membership of a Wi-Fi BSS in a bridge is **managed by the driver**, set at
init from the nvram. It is **the only** operation that cannot be done with a live
command (see §7). Ethernet/VLAN interfaces, however, are added normally.

---

## 4. AP / bridge mode and the DHCP path

Validated live: a DHCP request issued **on `br30`** gets a lease from the Ubiquiti:

```sh
udhcpc -i br30 -f -n -q -t 4 -s /bin/true
# → lease of 10.0.30.8 obtained   (Ubiquiti VLAN 30 DHCP server)
```

So the DHCP of a Wi-Fi client works **if and only if** its BSS is a member
of the corresponding VLAN bridge. This was the NetB bug: SSID on `wl3.2`, but `wl3.2`
was in no bridge → DHCP impossible.

**Testing the path without a Wi-Fi client**: `udhcpc -i br<vlan> -n -q -s /bin/true`
(the `-s /bin/true` avoids configuring an IP on the bridge → no side effects).

---

## 5. The SDN / Guest-Pro (apg) system — how a Wi-Fi VLAN works

On this firmware, a "guest network with VLAN" = an **`apg<N>` profile** linked to a
bridge via `sdn_rl` → `vlan_rl`. This is **the mechanism that works** (NetA is
the proof), not the hostapd-direct approach.

### nvram structures

```
apg3_ssid=NetB       apg4_ssid=NetA            # profiles (one per network)
apg_ifnames=br30 br20                                # existing SDN bridges
vlan_rl=<1>30>0><2>20>0>                             # idx1→VLAN30, idx2→VLAN20
apg_br30_fh_wlifnames=wl0.30 wl1.30 wl2.30 wl3.30    # Wi-Fi front-haul of br30
apg_br30_fh_ethifnames=eth0.30 eth1.30 eth2.30 eth3.30

sdn_rl=…<3>Customized>1>1>1>3>…<4>Customized>1>2>2>4>…
#         │              │ │ │                         entry 3 → vlan_idx 1 (VLAN30) → apg3
#         sdn_idx        │ vlan_idx                     entry 4 → vlan_idx 2 (VLAN20) → apg4
#                        enable        apg_idx
```

### ⭐ The decisive lever: `apg<N>_dut_list`

```
apg<N>_dut_list=<<redacted-mac>>0>   # flag 0 = BSS bridged in its VLAN   ✅
apg<N>_dut_list=<<redacted-mac>>1>   # flag 1 = isolated / not bridged    ❌ (NetB bug)
```

The final flag (`0`/`1`) decides whether the network's BSS is **attached to its VLAN bridge**.
NetB had `1` (isolated, `lanaccess=off`) → its interface was in no bridge.
Switching it to `0` (like NetA) then rebuilding the SDN put `wl3.2` into `br30`.

### Format of `apg<N>_security` (per-network password)

```
apg3_security=<3>pskpsk2>aes>REDACTED>3<13>pskpsk2>aes>REDACTED>3<16>sae>aes>REDACTED>3<96>sae>aes>REDACTED>3
#              <band>akm>crypto>psk>mfp ...  (one entry per band ; 6 GHz forced to sae)
```
If `apg<N>_security` is **empty** (NetA case), the SSID's security is inherited
from the main Wi-Fi settings. The blob is **undocumented by Asus** — to be handled
with care (one mistake = clients unable to authenticate).

### What the SDN does NOT contain

`vlan_rl` only lists **VLAN 20 and 30**. The `DEV-SCEP` network (VLAN 50) from
`networks.conf` **has no apg profile, no `br50`, no SDN entry**: it
has never existed as a VLAN. Creating a brand-new VLAN = creating a bridge + switch tag
(`ethswctl`/`vlanctl`) + `apg`/`sdn_rl`/`vlan_rl` (big project, separate).

---

## 6. WPA / authentication: who does what

Observed processes:

```
/bin/eapd                          EAP / WPS relay (Broadcom)
hostapd -B /tmp/wl0_hapd.conf      one hostapd process PER radio
hostapd -B /tmp/wl1_hapd.conf
hostapd -B /tmp/wl2_hapd.conf
hostapd -B /tmp/wl3_hapd.conf
```

- The **`wl` driver** creates the BSS and manages basic bridging/beacon.
- **`hostapd`** (one process per radio) handles the **WPA/WPA2/WPA3 handshake** on
  the BSS. Live state of a BSS: `wl -i wl3.2 wpa_auth` → `WPA-PSK WPA2-PSK`.
- **`eapd`** relays EAP (enterprise/802.1X) and WPS.

> Consequence: you can reload the WPA of **a single radio** (`hostapd_cli … reload`)
> without touching the others or doing a global `restart_wireless`.

---

## 7. Useful commands

### 7a. Diagnostics (read-only)

```sh
# Interfaces and bridges
brctl show                              # bridges + members
ip -br link                             # compact list of netdevs
for i in /sys/class/net/*; do d=$(basename $i); \
  echo "$d master=$(basename $(readlink $i/master 2>/dev/null))"; done   # iface → bridge

# Radio / BSS (driver)
wl -i wl3.2 ssid                        # broadcast SSID
wl -i wl3.2 bss                         # up / down
wl -i wl3.2 wpa_auth                    # active WPA mode
wl -i wl3.2 assoclist                   # associated clients (MAC)
wl -i wl3   chanspecs                   # available channels

# Clients / traffic
hostapd_cli -i wl3.2 all_sta            # station details (signal, bytes…)
cat /proc/net/arp                       # ARP table (mac → ip)
ip neigh show

# SDN / apg
nvram get apg3_ssid ; nvram get apg3_dut_list
nvram get sdn_rl | tr '<' '\n'
nvram get vlan_rl

# Test the DHCP of a VLAN without a Wi-Fi client
udhcpc -i br30 -f -n -q -t 4 -s /bin/true
```

### 7b. ⚡ Fast apply — without `restart_wireless`

`restart_wireless` rebuilds the entire stack (~30 s). For most changes,
targeted commands are enough (measured: `wl ssid` = 0.00 s, **without disconnection**):

| Change | Command | Cost |
|---|---|---|
| SSID | `wl -i <iface> ssid "<nom>"` | instant, no disconnect |
| Hidden SSID | `wl -i <iface> closed 0\|1` | instant |
| Client isolation | `wl -i <iface> ap_isolate 0\|1` | instant |
| Enable / disable | `wl -i <iface> bss up\|down` | instant |
| Password | rewrite the PSK in the hapd block → `hostapd_cli -i <iface> reload_wpa_psk` | instant, **no disconnect** |
| Security mode | rewrite the BSS block → `hostapd_cli -i <iface> reload` (or restart this single hostapd) | ~1–2 s, **a single band** |
| **VLAN / bridge** | managed by the driver (nvram + re-init) — `brctl` forbidden | only "heavy" case |

`hostapd_cli` (per interface) supports: `reload`, `reload_wpa_psk`, `enable`, `disable`.

### 7c. Heavy apply (to avoid unless a structural change)

```sh
service restart_wireless     # rebuilds the entire Wi-Fi + SDN (~30 s) — applies nvram/apg/vlan
nvram commit                 # persist the nvram to flash (slow, ~1 s)
```

---

## 8. Configuration files

### Project side (webui) — `/jffs/webui/`

| File | Role |
|---|---|
| `networks.conf` | source of truth for networks (`NET_<id>_<CLÉ>=…`) |
| `radius_servers.conf` | RADIUS servers (`RS_<id>_<CLÉ>=…`) |
| `auth.conf` | UI password hash (`SALT=`/`HASH=`, chmod 600) |
| `radios.conf` | channels saved per radio |
| `portfwd.conf`, `dhcp_static.conf` | NAT / static leases |
| `cgi-bin/api.sh` + `cgi-bin/lib/*.sh` | CGI backend |
| `www/*` | frontend |
| `httpd.sh`, `hostapd-watchdog.sh` | HTTP server (socat) + watchdog |
| `backup/` | nvram backups before modifications |

### Router side — runtime and persistent

| Path | Role | Persistence |
|---|---|---|
| `/tmp/wlX_hapd.conf` | active hostapd config (1 per radio) | tmpfs (lost on reboot) |
| `nvram` | Wi-Fi/SDN/apg config (real source of bridging) | flash (`nvram commit`) |
| `/jffs/scripts/services-start` | boot script (currently **empty**) | `/jffs` |
| `/jffs/scripts/service-event` | hook: reapplies on `restart wireless` | `/jffs` |
| `/var/run/hostapd/<iface>` | hostapd control sockets | tmpfs |
| `/tmp/home/root/.ssh/authorized_keys` | active SSH keys | tmpfs (restored from `/jffs/.ssh/`) |

---

## 9. Observed behaviours & pitfalls

- **`restart_wireless` revives hostapd**: after a `restart_wireless`, the 4 hostapd
  processes (including `wl3`, which had died) come back, and the `service-event` hook
  reapplies the webui's BSS blocks.
- **SSID shift bug (hostapd generator)**: in `/tmp/wl0_hapd.conf`, some BSS
  broadcast SSIDs literally named `psk2` and `enterprise` — the *security* value
  landed in the *ssid* field (shifted arguments). To be fixed.
- **Missing newline**: `/tmp/wl3_hapd.conf` contains `urnm_mfpr=0bss=wl3.2`
  (two directives glued together) + a duplicate `bss=wl3.2` → hostapd refused to
  start on `wl3` (2.4 GHz radio silent until the `restart_wireless`).
- **All VLAN sub-interfaces share the base MAC** `<redacted-mac>`;
  only the "slot" BSS have their own BSSID (`BA:…:Bx`).
- **6 GHz = mandatory WPA3-SAE** (otherwise BSS refused).
- **The main Asus SSID is forced onto `br0` (untagged admin LAN)** and the GUI
  refuses to disable it (the reason this project exists). The firmware **brings it
  back in <1 s** if you do `wl bss down` — impossible to *turn off*. But
  `wl -i <iface> closed 1` (hide) and `wl -i <iface> ssid ...` (rename)
  **hold**. The webui **masks** it (`closed 1`) via
  [`ssid-suppressor.sh`](../src/ssid-suppressor.sh): a watchdog that reads
  `/jffs/webui/suppress.conf` (one SSID per line) and re-applies `closed 1` every
  10 s, surviving the resets of `mtlancfg` (boot/restart_wireless). Started at
  boot via `services-start`. Concrete case: `MyPrivateNetwork` (`wl3.1`) → hidden.

---

## 10. Disabled Asus UI & SSH recovery access

We **no longer use the Asus web UI**: `:80` is redirected to our UI and `:8443`
(Asus HTTPS) is blocked. ⚠️ We **do NOT disable the Asus engine** (driver/SDN/
hostapd): we depend on it (cf. §5-6). Only the *web frontend* is neutralized.

Mechanism: [`/jffs/scripts/firewall-start`](../src/firewall-start) (re-run by
ASUSWRT after each (re)build of the firewall):
```sh
iptables -t nat -A PREROUTING -p tcp --dport 80 -j REDIRECT --to-ports 8080   # our UI
iptables -I INPUT ! -i lo -p tcp --dport 8443 -j DROP                          # Asus UI blocked
```
> `httpd`/`httpds` keep running (the `watchdog` would restart them anyway)
> — they are just **unreachable**. Reversible and watchdog-safe approach.

### SSH recovery access — guaranteed, independent of the UI

Dropbear (`:2222`) is the recovery access, with **3 persistent safeguards**:

| Safeguard | nvram / file | Effect |
|---|---|---|
| Service enabled at boot | `sshd_enable=2`, `sshd_port=2222` | dropbear always starts |
| Public key | `sshd_authkeys` (nvram) + `/jffs/.ssh/authorized_keys` | restored at boot |
| Password | `sshd_pass=1` | password login as a fallback |

### Re-enable the Asus UI (emergency)

```sh
iptables -D INPUT ! -i lo -p tcp --dport 8443 -j DROP      # unblock :8443
mv /jffs/scripts/firewall-start /jffs/scripts/firewall-start.off   # (and neutralize at boot)
# then https://10.0.0.8:8443/
```

## 11. Going further

> ⚠️ **Hard constraint (verified):** the WiFi↔VLAN bridging is **owned by
> `mtlancfg`/`cfg_server`** and can neither be replaced (`brctl` forbidden on the
> `wl*`) nor overridden from outside (`mtlancfg` regenerates `lanX_ifnames`, even
> when committed). The webui can override SSID/password/security, **not** create/bridge a
> WiFi VLAN. Details: [sdn_investigation.md](sdn_investigation.md).

- [SDN/mtlancfg investigation](sdn_investigation.md) — the constraint above, proven
- [architecture.md](architecture.md) — UI decisions (CGI shell, apply, auth)
- [hardware.md](hardware.md) — SoC, radios, storage
- [nvram_schema.md](nvram_schema.md) — nvram schema *(per-slot model — partially obsolete, see §5)*
- [hostapd_schema.md](hostapd_schema.md) — hostapd confs *(hostapd-direct approach — see §3)*
- [tools.md](tools.md) — inventory of system tools

## 12. Verified live snapshot (2026-06-03)

> Captured read-only via SSH (`admin@10.0.0.8:2222`). **Custom patched firmware**
> `GT-BE98 3.0.0.6_102.6`, build `Wed Jun  3 2026 root@ad42d5e`, BusyBox v1.25.1
> (157 applets). All secrets (PSK/SAE/RADIUS) are noted `<REDACTED>`.

### 12.1 BSS → SSID → bridge model (live)

| Interface | Band | SSID | State | Bridge / VLAN |
|---|---|---|---|---|
| `wl0` (primary) | 5 GHz-1 | random (hex) | `closed=1`, `bss=up` — hidden, unused | br0 |
| `wl0.1` | 5 GHz-1 | **NetA** | up | br20 (VLAN 20) |
| `wl1` (primary) | 5 GHz-2 | random | `closed=1`, up | br0 |
| `wl2` (primary) | 6 GHz | random | `closed=1`, up | br0 |
| `wl2.1` | 6 GHz | **NetA** | up | br20 (VLAN 20) |
| `wl3` (primary) | 2.4 GHz | random | `closed=1`, up | br0 |
| `wl3.1` | 2.4 GHz | *(empty)* | **`bss=down`** — MAINFH neutralized (patch 0025) | listed in br0/`lan_ifnames` but no BSS |
| `wl3.2` | 2.4 GHz | **NetB** | up | br30 (VLAN 30) |
| `wl3.3` | 2.4 GHz | **NetA** | up | br20 (VLAN 20) |
| `wl3.4` | 2.4 GHz | random | `bss=down` — management network, off | br0/`lan_ifnames` |

- **NetA** = tri-band (5 GHz-1 `wl0.1`, 6 GHz `wl2.1`, 2.4 GHz `wl3.3`).
- **NetB** = 2.4 GHz only (`wl3.2`).
- Bridges: `br0` = LAN (`10.0.0.8/24`); `br20`/`br30` = **L2** trunks (no IP, no
  DHCP on the bridge — consistent with the "L2 trunk" approach of `save_network`).
- `lan_ifnames = eth0..3 wl0 wl1 wl2 wl3 wl3.1 wl3.4`; `lan1_ifnames` (VLAN30) contains
  `wl3.2 …`; `lan2_ifnames` (VLAN20) contains `wl3.3 wl0.1 wl2.1 …`.

### 12.2 SDN/apg nvram profile (verified format — lifts the obsolescence of §5 of nvram_schema)

Format `<field>…` separated by `>`, entries separated by `<n>`:

```
sdn_rl = <0>DEFAULT…<1>MAINBH…<2>MAINFH…
         <3>Customized>1>1>1>3>…>WEB>…     # sdn_idx3, vlan_idx1, subnet_idx1, apg_idx3 → NetB
         <4>Customized>1>2>2>4>…>WEB>…     # sdn_idx4, vlan_idx2, subnet_idx2, apg_idx4 → NetA
vlan_rl   = <1>30>0>  <2>20>0>             # vlan_idx1=VLAN30, vlan_idx2=VLAN20
subnet_rl = <1>br54>192.168.30.1>255.255.255.0>0>…  <2>br55>192.168.20.1>255.255.255.0>0>…
            #   ^bridge ^gateway          ^dhcp_enable=0  → L3 subnet NOT applied (L2 trunk)
apg3_ssid=NetB     apg3_dut_list=<<redacted-mac>>1>    apg3_enable=1
apg4_ssid=NetA  apg4_dut_list=<<redacted-mac>>21>   apg4_enable=1
apg<N>_security = <band>akm>crypto>PASSWORD>mfp  (one entry per band)
   # NetB  : <3>pskpsk2>aes><REDACTED>>3  <13>pskpsk2>aes><REDACTED>>3  <16>sae>aes><REDACTED>>3 …  (WPA2/WPA3)
   # NetA: <3>sae>aes><REDACTED>>4    <13>sae>aes><REDACTED>>4 …                                 (SAE / pure WPA3)
```

- **`dut_list` band mask (confirmed)**: `wl3=1, wl0=4, wl1=8, wl2=16`.
  NetA `21 = 1+4+16` (2.4 GHz + 5 GHz-1 + 6 GHz); NetB `1` (2.4 GHz).
- ⚠️ `subnet_rl` names `br54`/`br55` with gateways `192.168.30.1`/`192.168.20.1`,
  but `dhcp_enable=0` → these L3 subnets **are not instantiated**; the VLANs
  remain L2 trunks on `br20`/`br30` (no IP). Keep this in mind if one day you want
  routed VLANs (cf. the L3 recipe in `plans/phase-b2-sdn-nvram-spec.md`).

### 12.3 MAINFH / firmware patch (live)

- `nvram get hapd_exclude_ifnames = wl3.1` → patch **0025 active**.
- `wl3.1`: `bss=down`, empty SSID → **no real beacon**. The interface still exists in
  `br0`/`lan_ifnames` but is inert. **No more watchdog** (`ssid-suppressor` /
  `bridge-enforcer`) running — `service-event` no longer restarts them, they are commented out
  in `services-start`. Confirms the "at the source" resolution described in §3 and in
  [sdn_investigation.md](sdn_investigation.md).

### 12.4 Processes & daemons (live)

| Process | State | Note |
|---|---|---|
| `socat -T 90 … EXEC:/jffs/webui/httpd.sh` | running | webui server (`:8080`) |
| `cfg_server` | running | owns the WiFi VLAN bridging (generates the `/tmp/wlX_hapd.conf`) |
| `networkmap` | running | respawned by the firmware (no nvram gate) |
| `roamast` | **running** | ⚠️ respawns despite `killall roamast` + `roamast_enable=0` in `services-start`; the effective key is `roamast_disable=1` (cf. phase notes) |
| `acsd` / `acsd2` | absent | disabled (`acs_disable=1`, `acsd2_disable=1`) |
| `infosvr` | absent | patch **0024** (gate `infosvr_enable`, default off) in effect ✓ |
| `envrams` | **running** | ⚠️ listens on `:5152` despite the `killall` in `services-start` **and** patch 0026 — respawned / gate not effective on the current build (to be fixed) |
| `ssid-suppressor` / `bridge-enforcer` | absent | removed (patch 0025) |

> ⚠️ **AP mode**: `sw_mode=3`, `lan_proto=dhcp` (the router gets its LAN IP from the
> Ubiquiti gateway). Many "router" daemons (wanduck, QoS, DPI/AiProtection,
> dnsmasq DHCP server) are therefore useless here. The stock daemons are launched by the
> monolithic binary `rc`/`services.c` (not by `/etc/init.d/`, which only contains
> the low-level init) and **respawned by `watchdog.c`**: those without an nvram gate can
> only be removed with a firmware patch (0024/0026 model). Full inventory of the
> stock surface & intended dispositions: `plans/plan-remove-stock-services.md`.

### 12.5 Radio channels (live)

`wl0 = 36/160` (5 GHz) · `wl1 = 108/80` (5 GHz) · `wl2 = 6g1/160` (6 GHz) · `wl3 = 1` (2.4 GHz).
`nvram wlX_chanspec=0` (auto) — the channels above are the ones actually selected.
nvram band: `wl0_nband=1`, `wl1_nband=1` (5 GHz), `wl2_nband=4` (6 GHz), `wl3_nband=2` (2.4 GHz).

### 12.6 Generated hostapd (`/tmp/wlX_hapd.conf`, by `cfg_server`)

Confs present: `wl0/wl1/wl2/wl3_hapd.conf`. Confirmed structure (cf. [hostapd_schema.md](hostapd_schema.md)):

- **Primary** (bridged `br0`): `driver=nl80211`, `ignore_broadcast_ssid=1` (hidden),
  `wpa_key_mgmt=WPA-PSK SAE SAE-EXT-KEY`, `wpa_pairwise=CCMP GCMP-256`, `ieee80211be=1`
  (Wi-Fi 7), `country_code=E0`, `owe_transition_ifname=wl0.4`.
- **NetA BSS** (`bss=wl0.1`, `bridge=br20`): `wpa_key_mgmt=SAE` (pure WPA3),
  `wpa_pairwise=CCMP`, `ieee80211w=2` (MFP required), `sae_password=<REDACTED>`.

### 12.7 Tools & scripts (live)

- Binaries present: `socat`, `lighttpd`, `brctl`, `ethswctl`, `wl`, `nvram`, `rc`,
  `hnd-write`, `iptables`, `ip`, `vconfig`, `hostapd`, `dnsmasq`, `jq`, `openssl`,
  `sha256sum`, `dhd`, `cfg_server`. ⚠️ **`mtlancfg` not found via `$PATH`** — the
  observed VLAN bridging is driven by `cfg_server`; check whether `mtlancfg` exists at
  another location before relying on it.
- **Boot hooks recovered from the router** (without secrets) in [`../scripts/`](../scripts):
  `firewall-start` (redirect `:80→:8080`, DROP `:8443` commented out), `service-event` (log
  only), `services-start` (kill roamast/acsd/envrams, `hapd_exclude_ifnames=wl3.1`,
  `http_enable=0`, SSH/port-forwards restoration, `socat`).
