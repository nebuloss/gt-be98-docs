# Current network topology — GT-BE98

## Overview

```
Internet (WAN)
     │
  [GT-BE98]
     │
  ┌──┴──────────────────────────────────────────┐
  │  br0 (native LAN — 10.0.0.8/24)            │
  │  eth0 eth1 eth2 eth3                        │
  │  wl0.0 wl1.0 wl2.0 wl3.0                   │
  │  wl3.1 wl3.4                                │
  └─────────────────────────────────────────────┘
     │
  ┌──┴──────────────────────────────────────────┐
  │  br20 (VLAN 20 — IP not configured)         │
  │  eth0.20 eth1.20 eth2.20 eth3.20            │
  │  wl0.1 wl0.20                               │
  │  wl1.1 wl1.20                               │
  │  wl2.1 wl2.20                               │
  │  wl3.1 wl3.20                               │
  │  SSID: "NetA" (all radios)              │
  └─────────────────────────────────────────────┘
     │
  ┌──┴──────────────────────────────────────────┐
  │  br30 (VLAN 30 — 192.168.2.1/24)            │
  │  eth0.30 eth1.30 eth2.30 eth3.30            │
  │  wl0.30 wl1.30 wl2.30 wl3.30               │
  │  wl3.2                                      │
  │  SSID: "NetB" (wl0 + wl3 only)            │
  │  DHCP: 192.168.2.2 – 192.168.2.254         │
  └─────────────────────────────────────────────┘
```

## Active interfaces

```
br0       10.0.0.8/24      main LAN
br20      (no IP)          VLAN 20 / NetA  ← DHCP missing !
br30      192.168.2.1/24   VLAN 30 / NetB
```

## Observed anomalies

1. **br20 without IP**: the VLAN 20 bridge has no IP address assigned and no DHCP configured. Clients on "NetA" cannot obtain an address.

2. **NetB missing from wl1 and wl2**: the "NetB" SSID is only active on wl0 (5G-1) and wl3 (2.4G), not on wl1 (5G-2) nor wl2 (6G).

3. **wl3.1 in br0**: `wl3.1` (NetA on 2.4G) is in both `lan_ifnames` (br0) AND br20. Dual membership to be fixed.

## Available BSS slots

```
Slot  VLAN   Status    Active radios
 .1    20    active    wl0 wl1 wl2 wl3
 .2    30    active    wl0 wl3 (wl1 wl2 missing)
 .3    —     FREE      —
 .4    —     special   wl3 (lanaccess=on, management)
 .5    —     FREE      —
 .6    —     FREE      —
 .7    —     FREE      —
```

## Ethernet LAN ports

The 4 ethernet ports (`eth0`–`eth3`) are currently all in `br0`.
To assign a physical port to a VLAN, you simply need to:
1. Remove `ethX` from `lan_ifnames`
2. Add `ethX.VID` to `lanY_ifnames`
(via ethswctl for tagging at the switch level)
