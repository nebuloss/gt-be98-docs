# The `wl` control interface (BCM6813 / impl105) — RE + open reimplementation

> **Verified live 2026-06-04.** The proprietary `wl` tool is just a thin userspace
> frontend over a single private ioctl. We reimplemented its read/diagnostic path as an
> open, dependency-free C tool ([`src/netctl/owl.c`](src/netctl/owl.c)) and validated it
> byte-for-byte against stock `wl` on the AP. No `wlioctl.h`, no `libwlcsm` needed — just
> the ABI below.

## The ioctl ABI (from `shared/wl_linux.c`)

Every `wl` operation is one `ioctl(SIOCDEVPRIVATE)` on an `AF_INET/SOCK_DGRAM` socket,
with `ifr.ifr_data` pointing at a `wl_ioctl_t`:

```c
typedef struct wl_ioctl {
    uint32 cmd;     /* WLC_* command number          */
    void  *buf;     /* user buffer (in for set/iovar name, out for get) */
    uint32 len;     /* buffer length                 */
    uint8  set;     /* 1 = set, 0 = query            */
    uint32 used, needed;
} wl_ioctl_t;       /* 24 bytes on 32-bit ARM: cmd,buf,len, set+3pad, used, needed */

s = socket(AF_INET, SOCK_DGRAM, 0);
ioc = { .cmd=cmd, .buf=buf, .len=len, .set=set };
strncpy(ifr.ifr_name, ifname, IFNAMSIZ-1);
ifr.ifr_data = (caddr_t)&ioc;
ioctl(s, SIOCDEVPRIVATE, &ifr);          /* == SIOCDEVPRIVATE, i.e. 0x89F0 */
```

`WLC_IOCTL_MAGIC = 0x14e46c77`. Per-BSS targeting is purely by `ifr_name` (`wl3.2`
etc.) — the same virtual netdevs the bridges use. No need for the `wl -i` prefix logic;
the netdev *is* the BSS.

## Command numbers used (from `wlioctl_defs.h`)

| name | # | buffer type | owl command |
|---|---|---|---|
| `WLC_GET_MAGIC` | 0 | int (==MAGIC) | (probe) |
| `WLC_UP` / `WLC_DOWN` | 2 / 3 | — | (radio up/down; not exposed in owl) |
| `WLC_GET_BSSID` | 23 | `ether_addr` (6B) | `bssid` |
| `WLC_GET_SSID` | 25 | `wlc_ssid_t` {u32 len; u8[32]} | `ssid` |
| `WLC_SET_SSID` | 26 | `wlc_ssid_t` | (set; hostapd re-asserts on managed BSS) |
| `WLC_GET_CHANNEL` | 29 | channel_info | — |
| `WLC_GET_RSSI` | 127 | int | — |
| `WLC_GET_BSS_INFO` | 136 | wl_bss_info_t | — |
| `WLC_GET_ASSOCLIST` | 159 | `maclist` {u32 count; ea[]} | `assoclist` |
| `WLC_GET_VAR` | 262 | iovar name → value | `getvar`, `chanspec`, `bss_enabled` |
| `WLC_SET_VAR` | 263 | iovar name+value | (set iovar) |

### iovars (string-named, via WLC_GET_VAR/SET_VAR)

The buffer starts with the NUL-terminated iovar name; the driver writes the result back
over the buffer. Verified working: `chanspec` (u16, e.g. `0xe02a` = ch36/80), `bss`
(int, 1=up — this is the real BSS up-state), `ver` (driver version string). Note:
`isup` is **not** a GET_VAR iovar on this driver (stock `wl isup` does it inside the
closed binary); use the `bss` iovar for BSS up-state instead.

## owl — open reimplementation

Build (32-bit ARM static, router glibc 2.32):
```sh
CC=.../crosstools-arm_softfp-gcc-10.3-linux-4.19-glibc-2.32-binutils-2.36.1/bin/arm-buildroot-linux-gnueabi-gcc
$CC -O2 -Wall -static -o owl src/netctl/owl.c   # ~425 KB stripped
```

Live validation vs stock `wl` (identical output):
```
wl0   ssid=BA9C…FB5B  bssid=60:CF:84:38:87:B4  chanspec=0xe02a  bss=1   # 5 GHz ch36/80
wl1   …               …                        chanspec=0xe26a  bss=1   # 5 GHz-2
wl2   …               …                        chanspec=0x680f  bss=1   # 6 GHz
wl3.2 ssid=DEV-SCEP   bssid=BA:CF:84:38:87:B2  chanspec=0x1001  bss=1   # 2.4 GHz ch1
wl3.3 ssid=Pagoa      bssid=BA:CF:84:38:87:B3  chanspec=0x1001  bss=1
```

This proves the control plane can read radio/BSS state without the closed `wl`. Writes
(`WLC_SET_SSID`, `WLC_SET_VAR`) use the same path (`set=1`) but on a hostapd-managed BSS
hostapd re-asserts its own config (see [netctl-verified.md](netctl-verified.md) P0.4), so
the durable control verbs stay in netctl (nvram + hostapd_cli). owl is the open,
auditable **read** path; extending it to the few safe write iovars (e.g. `closed`) is
straightforward when needed.

## RE references
- `shared/wl_linux.c` — `wl_ioctl()` (the SIOCDEVPRIVATE path).
- `bcmdrivers/broadcom/net/wl/impl105/main/components/wlioctl/include/wlioctl.h` —
  `wl_ioctl_t`, `wlc_ssid_t`.
- `…/wlioctl_defs.h` — `WLC_*` command numbers, `WLC_IOCTL_MAGIC`.
- `shared/wlutils.h` — `wl_iovar_get/set/getint` prototypes (the iovar wrappers owl inlines).
