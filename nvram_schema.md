# nvram Schema — Wi-Fi + VLAN

> ⚠️ **Partially obsolete.** The "one BSS per slot with `wlX.N_vlan` +
> auto-created `wlX.VID` alias" model described here does not match the actual
> behavior observed: VLAN bridging is driven by the **SDN/Guest-Pro (apg)** and the
> `apg<N>_dut_list` flag, not by `wlX.N_vlan`. Verified reference:
> [comportement.md](comportement.md) §3 and §5.
>
> 📌 **Live SDN/apg profile captured on the router** (actual `sdn_rl`/`vlan_rl`/
> `subnet_rl`/`apg<N>_*` format, confirmed `dut_list` band mask):
> [comportement.md](comportement.md) **§12.2**.

## Main radios (wlX)

```
wlX_ssid           main SSID
wlX_bss_enabled    1 = radio active
wlX_radio          1 = radio ON
wlX_channel        0 = auto, otherwise channel number
wlX_chanspec       Broadcom chanspec (e.g.: 0x1001 = auto)
wlX_nband          1=5GHz  2=2.4GHz  4=6GHz
wlX_bw_cap         band width bitmask (see hardware.md)
wlX_auth_mode_x    open | psk2 | sae | psk2sae
wlX_crypto         ccmp | aes+gcmp256
wlX_wpa_psk        password
wlX_akm            psk2 sae sae-ext  (space-separated list)
wlX_txpower        TX power (0-100)
wlX_country_code   E0 (Europe)
wlX_phytype        v = 802.11be
```

## Virtual BSS (wlX.N)

N is a logical index 1–7 (0 = native interface, not used directly).

```
wlX.N_ssid             SSID of this network
wlX.N_bss_enabled      1 = active
wlX.N_vlan             associated VLAN ID (e.g.: 20)
wlX.N_auth_mode_x      same values as the main radio
wlX.N_crypto           same values
wlX.N_wpa_psk          password
wlX.N_akm              modes list
wlX.N_ifname           wlX.N  (auto)
wlX.N_hwaddr           MAC (auto)
wlX.N_lanaccess        off = isolated from native LAN  on = LAN access
wlX.N_bridge           (empty = managed via lanY_ifnames)
wlX.N_mode             ap
wlX.N_infra            1
wlX.N_mfp              0=disabled 1=capable 2=required
wlX.N_closed           0=SSID visible  1=SSID hidden
wlX.N_ap_isolate       0=clients see each other  1=client isolation
```

## VLAN BSS alias (wlX.VID)

For each BSS with vlan=VID, the firmware automatically creates a `wlX.VID` alias:

```
wlX.VID_bss_enabled    1
wlX.VID_ssid           same SSID as wlX.N
```

These interfaces are added to the `brVID` bridge.

## LAN bridges (lanY)

```
lan_ifname      br0        native LAN bridge
lan_ifnames     eth0 eth1 eth2 eth3 wl0 wl1 wl2 wl3 ...
lan_ipaddr      10.0.0.8
lan_netmask     255.255.255.0

lan1_ifname     br30       VLAN 30 bridge
lan1_ifnames    eth0.30 eth1.30 eth2.30 eth3.30 wl0.30 wl1.30 wl2.30 wl3.30
lan1_ipaddr     192.168.2.1
lan1_netmask    255.255.255.0
lan1_proto      0

lan2_ifname     br20       VLAN 20 bridge
lan2_ifnames    eth0.20 eth1.20 eth2.20 eth3.20 wl0.20 wl1.20 wl2.20 wl3.20
```

Convention: `lanY_ifname = br{VID}`, `lanY_ifnames` lists all interfaces.

## DHCP per bridge

```
dhcp_enable_x       1 = DHCP active on br0
dhcp_start          192.168.50.2
dhcp_end            192.168.50.254
dhcp_lease          86400

dhcp1_enable_x      DHCP for lan1 (br30)
dhcp1_start         192.168.2.2
dhcp1_end           192.168.2.254
dhcp1_lease         86400

# dhcp2_ = br20 (not currently configured)
```

## Complete pattern — create a new network

To add the "IoT" network on VLAN 40, on all radios, slot index 3:

```sh
# --- BSS on each radio ---
for radio in 0 1 2 3; do
  nvram set wl${radio}.3_ssid="IoT"
  nvram set wl${radio}.3_bss_enabled=1
  nvram set wl${radio}.3_vlan=40
  nvram set wl${radio}.3_auth_mode_x=psk2sae
  nvram set wl${radio}.3_crypto=aes+gcmp256
  nvram set wl${radio}.3_wpa_psk="mypassword"
  nvram set wl${radio}.3_akm="psk2 sae sae-ext"
  nvram set wl${radio}.3_lanaccess=off
  nvram set wl${radio}.3_ap_isolate=0
  nvram set wl${radio}.3_mode=ap
  nvram set wl${radio}.3_infra=1
  # VLAN alias
  nvram set wl${radio}.40_bss_enabled=1
  nvram set wl${radio}.40_ssid="IoT"
done

# --- Bridge ---
nvram set lan3_ifname=br40
nvram set lan3_ifnames="eth0.40 eth1.40 eth2.40 eth3.40 wl0.40 wl1.40 wl2.40 wl3.40"
nvram set lan3_ipaddr=192.168.3.1
nvram set lan3_netmask=255.255.255.0
nvram set lan3_proto=0

# --- DHCP ---
nvram set dhcp3_enable_x=1
nvram set dhcp3_start=192.168.3.2
nvram set dhcp3_end=192.168.3.254
nvram set dhcp3_lease=86400

nvram commit
service restart_wireless
```

## Delete a network

```sh
for radio in 0 1 2 3; do
  nvram set wl${radio}.3_bss_enabled=0
  nvram unset wl${radio}.40_bss_enabled
  nvram unset wl${radio}.40_ssid
done
nvram unset lan3_ifname
nvram unset lan3_ifnames
nvram unset lan3_ipaddr
nvram unset dhcp3_enable_x
nvram commit
service restart_wireless
```

## Slot index → existing VLANs

| Slot (N) | VLAN | SSID | Radios |
|---|---|---|---|
| .1 | 20 | NetA | wl0 wl1 wl2 wl3 |
| .2 | 30 | NetB | wl0 wl3 |
| .3 | free | — | — |
| .4 | — | management (wl3.4 lanaccess=on) | wl3 |
| .5–.7 | free | — | — |
