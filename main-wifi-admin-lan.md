# Main WiFi bound to the untagged admin LAN — behaviour & remediation

> **Verified live on the router 2026-06-04** (GT-BE98, AP mode `sw_mode=3`, custom
> gnuton/Merlin firmware). All SSIDs/BSSIDs/MACs in this doc are **redacted** —
> they are device-specific secrets. Reproduce with the `wl`/`nvram`/`brctl`
> commands shown.

## Summary of the problem

Each radio's **primary BSS** (`wl0`, `wl1`, `wl2`, `wl3`) is bridged onto **`br0`,
the untagged admin LAN**. It carries a **hidden, randomized hex SSID** (WPA2/WPA3).
The stock Asus GUI offers **no way to disable this main/default WiFi** — it is the
"management" SSID of the DEFAULT SDN profile. Because it sits on `br0`, any station
that joins it (the SSID is hidden but still joinable if name + PSK are known) lands
directly on the **admin LAN**. That is the security exposure we want to remove.

This is structurally the same class of problem as MAINFH (`wl3.1`), but it concerns
the **head interface** of each radio rather than a secondary BSS, so the MAINFH fix
(`hapd_exclude_ifnames`) does **not** apply here — see [§ Remediation](#remediation).

## Verified topology (live)

### Bridges → roles

| Bridge | Role | WiFi members (BSS) | Ethernet |
|---|---|---|---|
| `br0`  | **Untagged admin LAN** (management) | `wl0.0`,`wl1.0`,`wl2.0`,`wl3.0` (primary BSS), `wl3.1` (MAINFH, **down**), `wl3.4` (AiMesh backhaul, **down**) | `eth0`–`eth3` (untagged) |
| `br20` | VLAN 20 — user net "NetA" (`192.168.20.0/24`) | `wl0.1`, `wl2.1`, `wl3.3`, `wl{0,1,2,3}.20` | `eth0.20`–`eth3.20` |
| `br30` | VLAN 30 — user net "NetB" (`192.168.30.0/24`) | `wl3.2`, `wl{0,1,2,3}.30` | `eth0.30`–`eth3.30` |

Note the interface-naming quirk: `nvram lan_ifnames` lists the primary as `wl0 wl1
wl2 wl3`, but in `brctl show` the primary BSS appears as **`wlX.0`**.

### Radio → band map (unchanged from CLAUDE.md)

`wl0`=5 GHz-1, `wl1`=5 GHz-2, `wl2`=6 GHz (SAE only), `wl3`=2.4 GHz.

### SDN / apg model (`sdn_rl`, `apgN_*`)

| SDN idx | Name | Meaning | apg | VLAN |
|---|---|---|---|---|
| 0 | DEFAULT | Admin LAN — the **main WiFi** lives here (primary BSS on `br0`) | — | untagged |
| 1 | MAINBH | AiMesh main backhaul (`wl3.4`, bss **down**) | — | — |
| 2 | MAINFH | `wl3.1` / "MyPrivateNetwork" (bss **down**, `hapd_exclude_ifnames=wl3.1`) | — | — |
| 3 | Customized | User net "NetB" | `apg3` (enabled) | 30 |
| 4 | Customized | User net "NetA" | `apg4` (enabled) | 20 |

`apg3_dut_list`/`apg4_dut_list` bind the SSID to this DUT with a band mask (the
firmware's `dut_list` model). `subnet_rl` additionally defines L3 subnet bridges
(`br54`→`192.168.30.1`, `br55`→`192.168.20.1`) with gateway IPs, but in **AP mode**
the L3 gateway/DHCP for those VLANs is owned by the **upstream** router, so the
runtime VLAN bridges are the L2 `br20`/`br30` (matching the L2-VLAN-trunk model in
CLAUDE.md).

### How the primary BSS is generated

`cfg_server` (closed) regenerates `/tmp/wlX_hapd.conf` at every
`restart_wireless`. The primary is emitted as the **head `interface=` line** of the
file, then the virtual BSS are chained under it:

```
interface=wl0            # <- primary BSS = the main WiFi
bridge=br0               #    bridged to the admin LAN
ssid=<RANDOM-HEX-SSID>   #    hidden, randomized
ignore_broadcast_ssid=1  #    (wl0_closed=1)
wpa=2
bss=wl0.1                # <- virtual BSS (user net)
bridge=br20
ssid=NetA
...
```

hostapd **requires** a `interface=` head line; the `bss=` virtuals are children of
it. This is why the primary cannot simply be "excluded".

## Experiments (2026-06-04, no clients associated during testing)

### E1 — runtime `wl bss down` on the primary → virtuals survive ✅

```sh
wl -i wl0 bss down      # bring primary BSS down at runtime
# RESULT: wl0 bss=down, wl0.1 bss=UP (NetA still beaconing), wl0 radio still enabled
wl -i wl0 bss up        # fully reversible
```

**Conclusion:** the primary BSS can be neutralized at runtime **without** taking
down the radio or its virtual (user) networks. **Not persistent** — a
`restart_wireless` (or reboot, or any webui `save_network`) brings it back up.

### E2 — `nvram wlX_bss_enabled=0` on the primary → tears down the whole radio ❌

```sh
nvram set wl0_bss_enabled=0; nvram commit; restart_wireless
# RESULT: /tmp/wl0_hapd.conf is NOT generated at all.
#         wl0 primary down AND wl0.1 (NetA on 5 GHz-1) GONE — the entire
#         wl0 hapd instance (primary + its virtuals) is removed.
nvram set wl0_bss_enabled=1; nvram commit; restart_wireless   # restored
```

**Conclusion:** `bss_enabled=0` is **not** a clean removal path for the primary —
it does not "promote" the first virtual to the head interface; it drops the radio's
whole hapd instance, killing the user nets on that radio.

### E3 — MAINFH / backhaul already neutralized ✅

`wl3.1` (MAINFH) and `wl3.4` (AiMesh backhaul) are both `bss=down` at runtime;
`hapd_exclude_ifnames=wl3.1` is set (firmware patch 0025). No live exposure from
these two.

### E4 — "No WiFi by default" is a clean, reachable state ✅

```sh
for i in wl0 wl1 wl2 wl3 wl0.1 wl2.1 wl3.2 wl3.3; do wl -i $i bss down; done
# RESULT: every BSS down; radios still ENABLED (wl -i wlX radio = 0x0000);
#         management over ethernet (br0 uplink, 10.0.0.x) completely unaffected.
restart_wireless    # restores everything from nvram
```

**Conclusion:** all WiFi can be brought down with the radios left enabled and the
box still fully manageable over the wired uplink. This is the desired idle/default
state ("router ships with no WiFi until the user creates one").

### E5 — The primary can be repurposed as a user net on a VLAN ✅ (runtime)

Goal: make the first user net (**NetA**) take over the primary interface and
bind it to **VLAN 20**, instead of leaving the hidden admin SSID on `br0`.

```sh
brctl delif br0  wl0.0          # off the admin LAN
brctl addif br20 wl0.0          # onto VLAN 20
wl -i wl0 closed 0              # unhide
wl -i wl0 ssid "NetA"       # rename the primary
# RESULT: wl0 now beacons "NetA", bss=up, member of br20, removed from br0.
restart_wireless                # reverts to the hidden hex SSID on br0
```

**Conclusion:** the primary BSS *can* serve a named user net on a tagged VLAN — the
admin-LAN exposure disappears. Two caveats:
1. **Runtime-only.** `restart_wireless` regenerates the primary from the DEFAULT SDN
   (hidden hex, `br0`). Persistence needs either a re-apply hook or, cleanly, the
   webui owning hostapd (see Target design).
2. `wl ssid` changes only the broadcast SSID; the **WPA passphrase/auth** still come
   from the hostapd config bound to `interface=wl0`. A real client login as NetA
   requires rewriting `/tmp/wl0_hapd.conf` (passphrase + auth) — i.e. the
   hostapd-direct path, not a pure `wl`/`brctl` runtime poke.

### E6 — Primary SSID + security ARE nvram-driven and persistent ✅

```sh
nvram set wl0_ssid=LABTEST0 ; nvram set wl0_closed=0 ; nvram commit
restart_wireless ; restart_sdn
# RESULT: survives BOTH. nvram + live + /tmp/wl0_hapd.conf all show LABTEST0,
#         unhidden. cfg_server did NOT revert it from the apm1 master profile.
```

**Conclusion:** the primary's SSID, hidden flag, and WPA params come from the
`wlX_*` nvram (`wlX_ssid`, `wlX_closed`, `wlX_akm`/`wlX_crypto`/`wlX_wpa_psk`) and a
plain webui apply (`restart_wireless;restart_sdn`) does **not** overwrite them. So the
webui *can* drive the primary's identity directly via nvram. (A full `cfg_server`
re-sync from `common.json` / a reboot was not separately stress-tested — worth a
reboot check before relying on it.)

### E7 — Primary's bridge/VLAN is NOT nvram-controllable ❌

```sh
# move wl0 out of br0 members and into br20 (lan2) members:
nvram set lan_ifnames="eth0 eth1 eth2 eth3 wl1 wl2 wl3 wl3.1 wl3.4"
nvram set lan2_ifnames="wl0 wl3.3 wl0.1 ... eth0.20 ..."
nvram commit ; restart_wireless
# RESULT: /tmp/wl0_hapd.conf STILL emits  interface=wl0 / bridge=br0,
#         and wl0.0 ends up in br0 (admin) anyway.
```

**Conclusion:** `cfg_server` derives the primary's `bridge=` from the **DEFAULT SDN
model**, not from `lan_ifnames`. The admin-LAN binding of the primary cannot be moved
to a VLAN by nvram alone — it requires either the firmware/`cfg_server` change, or a
**runtime `brctl` enforcer** that re-homes `wlX.0` after each wireless restart (the
E5 mechanic). (All test nvram restored to originals afterwards.)

### Net conclusion for the design

| Primary attribute | Controllable via nvram (persistent)? |
|---|---|
| SSID / hidden flag / WPA auth+psk | **Yes** (`wlX_ssid`,`wlX_closed`,`wlX_akm`,`wlX_crypto`,`wlX_wpa_psk`) — E6 |
| BSS up/down | No clean nvram path (E2 destroys the radio); runtime `wl bss down` works (E1) |
| Bridge → VLAN | **No** — `cfg_server` forces `br0` from the DEFAULT SDN (E7) |

So the SSID/security half of "NetA adopts the primary" is reachable from the
webui today; the **VLAN-bind half is the part that needs the firmware work** (or a
runtime brctl enforcer as a stopgap).

### E8 — Per-radio hostapd → runtime edits without a global outage ✅

One `hostapd` per radio (`hostapd /tmp/wlX_hapd.conf -B`) with per-BSS control
sockets in `/var/run/hostapd/`. Verified: `wl -i <bss> ssid` changes a **virtual**
BSS instantly with siblings untouched; `SIGHUP` to one radio's hostapd reloads only
that band (the other three stay up). So WiFi edits need not go through
`restart_wireless`. Full analysis + proposed apply model:
[wifi-apply-no-outage.md](wifi-apply-no-outage.md).

### Timing note

`restart_wireless` takes **>20 s** to fully bring all BSS back up, the 2.4 GHz radio
(`wl3`) being slowest — a BSS reading `down` ~20 s after the restart is usually still
settling, not a failure. Re-check after ~30 s.

## Target design (decided)

There must be **no hidden management SSID on `br0`**. The model:

1. **Default = no WiFi.** With no user networks defined, every BSS is down (E4); the
   radios stay enabled and the box is managed over the wired uplink only.
2. **The first user net adopts the primary interface, bound to its VLAN.** Concretely
   for this site: **NetA is the first WiFi → it takes over the primary BSS
   (`wl0`/`wl1`/`wl2`/`wl3`) and is bridged to VLAN 20 (`br20`)** — replacing the
   hidden hex admin SSID entirely. The primary is repurposed, not left dangling on
   the admin LAN. E5 proves the SSID + bridge mechanic works.
3. **Subsequent user nets use virtual BSS** (`wlX.Y`) on their own VLANs, as today
   (NetB on VLAN 30, etc.).

This is the **hostapd-direct ownership** model from CLAUDE.md / Phase 3 option (b):
the webui writes the hapd configs and bridges, instead of letting `cfg_server`
regenerate the DEFAULT-SDN primary on `br0`.

### Why this needs the firmware work first

In the current stack `cfg_server` regenerates `/tmp/wlX_hapd.conf` from the DEFAULT
SDN on every `restart_wireless` — re-emitting the primary as the hidden hex SSID on
`br0` (E5 caveat 1). Two constraints:
- **`hapd_exclude_ifnames` cannot help here.** It strips a *secondary* BSS (how
  MAINFH was fixed); the primary is the **head `interface=` line** and excluding it
  drops every virtual BSS chained under it — exactly the destructive effect seen in
  **E2**.
- A clean, persistent implementation therefore needs `cfg_server` removed/neutralized
  (firmware repo) so nothing regenerates hostapd. Per CLAUDE.md Phase 3: *"once
  cfg_server is removed, nothing regenerates hostapd anymore → the hostapd-direct
  approach becomes viable again."* That is the unlock for this design.

### Implementation path

| Stage | Action | Where |
|---|---|---|
| 1 (now, validated) | Confirm mechanics on hardware (E4 = all-down clean; E5 = primary→NetA/VLAN20). | live router |
| 2 (firmware) | Remove/neutralize `cfg_server` so it stops regenerating the DEFAULT primary on `br0`. | `../gt-be98-firmware` |
| 3 (webui) | webui owns hostapd: default writes all-BSS-down; "create first net" writes `interface=wlX ssid=<name> bridge=br<vid>` (NetA→`br20`) incl. WPA passphrase/auth; later nets → virtual BSS. | `cgi-bin/lib/networks.sh` |

### Interim fallback (only if a fix is needed before stage 2)

A runtime enforcer re-applying E5 after each `restart_wireless` (rewrite the primary
hapd conf or `wl ssid` + `brctl` move, plus the passphrase) — same pattern as the
retired `ssid-suppressor.sh`. Carries E5 caveat 2 (must also set WPA params), so it is
strictly a stopgap; the stage-2/3 path is the real fix.

## Reproduction cheatsheet

```sh
brctl show                                   # bridge membership (which BSS on br0)
nvram get lan_ifnames                         # br0 members (primary = wl0..wl3)
for u in 0 1 2 3; do wl -i wl$u bss; done     # primary BSS up/down
grep -E '^(interface|bss=|bridge|ssid)' /tmp/wl0_hapd.conf   # generated hapd layout
nvram get sdn_rl ; nvram get apg3_dut_list    # SDN / apg model
```
