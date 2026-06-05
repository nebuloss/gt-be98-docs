# gowl — native Go `wl` ioctl package (no shelling to `wl`)

Pure-Go (no cgo) reimplementation of the **read path** of Broadcom's closed `wl` for the
GT-BE98 (BCM6813, impl105), for **webui-go to import** instead of shelling out. It is the Go
sibling of the C [`owl`](../netctl/owl.c): same `ioctl(SIOCDEVPRIVATE)` + `wl_ioctl_t` ABI
(see [../../wl-interface.md](../../wl-interface.md)), zero dependencies.

## Verified byte-identical to stock `wl` on the AP [V]

Cross-compiled `GOARCH=arm GOARM=7 CGO_ENABLED=0` → a **1.5 MB static, libc-free** ARM EABI5
binary; run on the live router against stock `wl`:

```
wl0 ssid        BA9C09E1399AB24D897653DCD444FB5B   == gowl   MATCH
wl2 chanspec    0x680f                             == gowl   MATCH
wl3.2 ssid      DEV-SCEP                           == gowl   MATCH
wl0.1 bssid     6A:CF:84:38:87:B5                  == gowl   MATCH
wl2 bss_enabled 1                                  == gowl   MATCH
wl3.5 ssid      Pagoa / wl2.1 assoclist 0          == gowl   MATCH
```

## API (`package gowl`, module `gtbe98/gowl`)

```go
gowl.SSID(ifname)        (string, error)   // WLC_GET_SSID 25
gowl.BSSID(ifname)       (string, error)   // WLC_GET_BSSID 23  -> "AA:BB:.."
gowl.Chanspec(ifname)    (uint16, error)   // iovar "chanspec"
gowl.BSSEnabled(ifname)  (bool, error)     // iovar "bss" (1=up)
gowl.AssocList(ifname)   ([]string, error) // WLC_GET_ASSOCLIST 159
gowl.GetVar(ifname,name) ([]byte, error)   // generic WLC_GET_VAR 262 probe
// layout-trivial SETs (mirror the direct-WiFi recipe; use on driver-owned, not hostapd, BSS):
gowl.SetSSID(ifname,ssid)  error           // WLC_SET_SSID 26
gowl.SetBSS(ifname,up)     error           // iovar "bss" set
gowl.RemoveInterface(ifname) error         // iovar "interface_remove"
```

Targeting is purely by `ifname` (`wl3.2` etc.) — the netdev *is* the BSS.

## Build

```sh
cd src/gowl
GOARCH=arm GOARM=7 CGO_ENABLED=0 go build -ldflags "-s -w" -o gowl ./cmd/gowl   # router binary
go vet ./...                                                                     # host check
```

The `cmd/gowl` CLI mirrors `owl`'s verbs for diffing:
`gowl <ifname> ssid|bssid|chanspec|bss_enabled|assoclist|getvar <name>`.

## Scope (honest, mirrors owl.c)

`gowl` is the open **read** path for the small, fixed-layout iovars/ioctls, plus the
layout-trivial SET verbs. Deliberately **not** here:

- **Bulk/version-stamped blobs** — `scanresults` (`wl_bss_info_t`) and `counters`
  (`wl_cnt_t`) are large and version-specific (offsets vary per driver build); the robust
  path stays the stock `wl` text parser that `netctl scan`/`clients` wrap.
- **`interface_create`** — needs the versioned `wl_interface_create` struct (this driver
  reports `wlc_ver 9`); creation stays in `netctl` via stock `wl interface_create ap` for
  now. `RemoveInterface` (the simple half) is included.

webui-go can import `gtbe98/gowl` for the audited read path and add the create struct when
the versioned layout is pinned.
