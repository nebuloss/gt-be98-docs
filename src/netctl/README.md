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
| `ssid <bss> <name>` | rename one BSS, no outage | safe [V] |
| `hide`/`show <bss>` | hide/unhide one BSS, no outage | safe [V] |
| `bss <bss> up\|down` | enable/disable one BSS | safe [V] |
| `bridge <bss> <br>` | move a WiFi BSS to a VLAN bridge (`brctl`) | safe [V] |
| `net-create <apg> <vid> <ssid> <psk> [--apply]` | create an SDN WiFi VLAN | restart_wireless [V] |
| `net-delete <apg> [--apply]` | tear down an SDN WiFi VLAN | restart_wireless [V] |
| `commit` | persist running nvram after verifying | — |
| `deadman [secs]` / `keep` | dead-man reboot / disarm | safety |
| `snapshot [file]` | dump nvram for reversible tests | safe |

`[V]` = verified live on the AP. `net-create`/`net-delete` print a plan unless
`--apply` is given; without `commit` the change is uncommitted (a reboot reverts it).

## Verified create/delete flow (see ../netctl-verified.md for the RE detail)

```
netctl deadman 600                                  # arm self-recovery
netctl net-create 5 40 MyNet 's3cretpass' --apply   # apg5, VID40 -> br40, BSS beacons
#   ...verify the SSID beacons and SSH still works...
netctl keep ; netctl commit                         # disarm + persist
# later:
netctl net-delete 5 --apply ; netctl commit         # clean teardown
```

Caveat (verified): a *new* net is allocated a single 2.4 GHz band by
`rc sync_apgx_to_wlunit`; multi-band on a new CLI-created net is not yet solved.

## Safety guarantees (enforced in code)

- Never operates on `br0`, `eth0-3`, or the primary `wlX.0` BSS (admin/SSH path).
- `net-delete` refuses the built-in `DEFAULT`/`MAINBH`/`MAINFH` SDN entries.
- Structural applies leave nvram uncommitted; `deadman` arms a self-recovery reboot.
