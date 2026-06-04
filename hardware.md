# GT-BE98 — Hardware Reference

## SoC
- **Chip**: Broadcom BCM6813 (aka bcm4916 platform)
- **CPU**: ARM Cortex-A55
- **RAM**: 2 GB (2047960 kB observed)
- **Flash**: NAND via UBI volumes

## Storage
| Mount | Size | Free | Notes |
|---|---|---|---|
| `/` | 61 MB | 0 | Read-only squashfs (firmware) |
| `/jffs` | 44.5 MB | ~40 MB | **Persistent R/W** — scripts, configs |
| `/data` | 16.8 MB | ~15 MB | Persistent R/W |
| `/tmp` | 1000 MB | ~999 MB | tmpfs — lost on reboot |
| `/var` | 1000 MB | ~999 MB | tmpfs |

→ **UI repository**: `/jffs/`

## Wi-Fi radios (4 radios — Wi-Fi 7 / 802.11be)

| Interface | Band | nband | bw_cap | Max BW | Protocol |
|---|---|---|---|---|---|
| `wl0` | 5 GHz (radio 1) | 1 | 15 (0b01111) | 160 MHz | 11be |
| `wl1` | 5 GHz (radio 2) | 1 | 7  (0b00111) | 80 MHz  | 11be |
| `wl2` | 6 GHz | 4 | 31 (0b11111) | **320 MHz** | 11be |
| `wl3` | 2.4 GHz | 2 | 3  (0b00011) | 40 MHz  | 11be |

`bw_cap` bitmask: bit0=20 / bit1=40 / bit2=80 / bit3=160 / bit4=320 MHz

**Max BSS per radio: 8** (slots wlX.1 → wlX.7, wlX.0 = untagged native interface)

## Ethernet switch
- 4 LAN ports: `eth0` `eth1` `eth2` `eth3`
- Management tools: `ethswctl`, `vlanctl`
- VLAN tagging: via `vconfig` or `ip link add link ethX name ethX.VID type vlan id VID`

## Supported Wi-Fi security
| nvram mode | Description |
|---|---|
| `open` | Open |
| `psk2` | WPA2-PSK |
| `sae` | WPA3-SAE |
| `psk2sae` | WPA2/WPA3 mixed (recommended) |

Available crypto: `aes+gcmp256` (WPA3), `ccmp` (WPA2)
