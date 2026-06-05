# netctl — open network/WiFi/VLAN manager for the ASUS GT-BE98

Pure-POSIX-sh reimplementation of the network-management role of the proprietary
`cfg_server`/`mtlancfg`, using only the stock CLIs present on the router
(`nvram`, `wl`, `hostapd_cli`, `brctl`, `rc`, `service`). One file: `netctl.sh`.

Runs **on the router** (`/bin/sh /jffs/netctl.sh <cmd>`). It sets
`PATH=/bin:/usr/bin:/sbin:/usr/sbin` itself (so `sh`=busybox, not the Broadcom
`/sbin/sh` memory tool, while `rc`/`service` still resolve).

## Commands

| Command | What | Risk |
|---|---|---|
| `status` | radios + SDN networks + bridges + clients | safe [V] |
| `net-list` | list SDN networks from `sdn_rl`+`apg<N>` | safe [V] |
| `vlan-list` | VLAN bridges + BSS/fronthaul/eth members | safe [V] |
| `clients [bss]` | associated stations (+signal/rate via hostapd_cli) | safe [V] |
| `channels` | per-radio chanspec + ACS exclusions | safe [V] |
| `scan <radio>` | site survey: neighbor BSS table + channel occupancy | brief blip [V] |
| `ssid <bss> <name>` | rename one BSS, no outage (`hostapd_cli set ssid`) | safe [V] |
| `hide`/`show <bss>` | hide/unhide one BSS, no outage | safe [V] |
| `bss <bss> up\|down` | enable/disable one BSS (`hostapd_cli disable/enable`) | safe [V] |
| `bridge <bss> <br>` | move a WiFi BSS to a VLAN bridge (`brctl`) | safe [V] |
| `net-create <apg> <vid> <ssid> <psk> [--bands 2.4,5,6\|all] [--apply]` | create an SDN WiFi VLAN (multi-band) | restart_wireless [V] |
| `net-delete <apg> [--apply]` | tear down an SDN WiFi VLAN | restart_wireless [V] |
| `net-edit <apg> ssid <name>` | rename all of an apg's BSS, no outage | safe [V] |
| `commit` | persist running nvram after verifying | — |
| `deadman [secs]` / `keep` | dead-man reboot / disarm | safety |
| `snapshot [file]` | dump nvram for reversible tests | safe |

`[V]` = verified live on the AP. `net-create`/`net-delete` print a plan unless
`--apply` is given; without `commit` the change is uncommitted (a reboot reverts it).

## Verified create/delete flow (see ../netctl-verified.md for the RE detail)

```
netctl deadman 600                                  # arm self-recovery
netctl net-create 5 40 MyNet 's3cretpass' --apply   # apg5, VID40 -> br40, 3 bands beacon
#   ...verify the SSID beacons and SSH still works...
netctl keep ; netctl commit                         # disarm + persist
# later:
netctl net-delete 5 --apply ; netctl commit         # clean teardown
```

`--bands` selects the radios the new net beacons on (the band count comes from the
`apg<N>_dut_list` mask, not the security blob — see ../netctl-verified.md "Band-mask
encoding"). Tokens: `2.4` `5` (both 5 GHz) `5l` `5h` `6` `all`. Default `2.4,5` (mask 13,
the same 3-band shape as the stock user nets). Verified live incl. `--bands all` (4 bands,
6 GHz on `wl2`):
```
netctl net-create 5 40 MyNet 's3cretpass' --bands all --apply   # wl3+wl0+wl1+wl2 all beacon
netctl net-create 5 40 IoT   's3cretpass' --bands 2.4 --apply   # 2.4 GHz only
```

Caveat (verified): a *new* net is allocated a single 2.4 GHz band by
`rc sync_apgx_to_wlunit`; multi-band on a new CLI-created net is not yet solved.

## owl — open `wl` (read/diagnostic path)

`owl.c` is a dependency-free C reimplementation of the read side of Broadcom's closed
`wl`, talking to the driver via the raw `SIOCDEVPRIVATE`/`wl_ioctl_t` ABI. Verified
byte-identical to stock `wl` for `ssid`/`bssid`/`chanspec`/`bss_enabled`/`assoclist`/
`getvar`. Build (32-bit ARM static, glibc 2.32):

```sh
CC=.../arm-buildroot-linux-gnueabi-gcc
$CC -O2 -Wall -static -o owl owl.c
owl wl3.2 ssid     # -> DEV-SCEP
owl wl0  chanspec  # -> 0xe02a
```

See [../../wl-interface.md](../../wl-interface.md) for the full ioctl ABI + command map.

## Safety guarantees (enforced in code)

- Never operates on `br0`, `eth0-3`, or the primary `wlX.0` BSS (admin/SSH path).
- `net-delete` refuses the built-in `DEFAULT`/`MAINBH`/`MAINFH` SDN entries.
- Structural applies leave nvram uncommitted; `deadman` arms a self-recovery reboot.
