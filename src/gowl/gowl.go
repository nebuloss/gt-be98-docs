// Package gowl is a dependency-free, pure-Go reimplementation of the read/diagnostic
// path of Broadcom's proprietary `wl` tool for the GT-BE98 (BCM6813, impl105 driver).
//
// It talks to the wl driver exactly the way the open shared/wl_linux.c (and the C `owl`)
// does: one ioctl(SIOCDEVPRIVATE) carrying a wl_ioctl_t {cmd,buf,len,set,...}. No cgo, no
// wlioctl.h, no libwlcsm — just the ABI. Built for the router's 32-bit ARM userspace
// (GOARCH=arm GOARM=7 CGO_ENABLED=0 -> a static, libc-free binary).
//
// Verified byte-identical to stock `wl` on the AP for ssid/bssid/chanspec/bss_enabled/
// assoclist/getvar. See ../../wl-interface.md for the ioctl ABI and command map.
//
// Scope (mirrors owl.c): the OPEN READ path for the small, FIXED-layout iovars/ioctls,
// plus the layout-trivial SET verbs (SetSSID, BSS up/down). Bulk/version-stamped blobs
// (scanresults, counters) are deliberately left to the stock `wl` text parser that
// `netctl scan`/`clients` wrap — their wl_bss_info_t/wl_cnt_t offsets vary per driver
// build. interface_create/remove need the versioned wl_interface_create struct and are
// noted as the next step (see RemoveInterface for the simple half).
package gowl

import (
	"encoding/binary"
	"fmt"
	"runtime"
	"syscall"
	"unsafe"
)

// WLC command numbers (from wlioctl_defs.h).
const (
	wlcGetMagic     = 0
	wlcGetBSSID     = 23
	wlcGetSSID      = 25
	wlcSetSSID      = 26
	wlcGetAssocList = 159
	wlcGetVar       = 262
	wlcSetVar       = 263

	siocDevPrivate = 0x89f0 // SIOCDEVPRIVATE
	wlcIoctlMagic  = 0x14e46c77
	maxSSID        = 32
)

// wlIoctl mirrors the kernel wl_ioctl_t. On 32-bit ARM this is 24 bytes:
// cmd(4) buf(4,ptr) len(4) set(1)+pad(3) used(4) needed(4).
type wlIoctl struct {
	cmd    uint32
	buf    uintptr
	length uint32
	set    uint8
	_      [3]byte
	used   uint32
	needed uint32
}

// ifreq with ifr_data pointing at the wlIoctl. name[16] + a 16-byte union region
// (we write ifr_data as a pointer into the head of the union) = 32 bytes, arch-agnostic.
type ifreq struct {
	name  [16]byte
	union [16]byte
}

func ioctl(fd int, req uintptr, arg unsafe.Pointer) syscall.Errno {
	_, _, e := syscall.Syscall(syscall.SYS_IOCTL, uintptr(fd), req, uintptr(arg))
	return e
}

// rawIoctl issues one WLC ioctl against ifname. buf is the in/out buffer; on a GET the
// driver writes its result back over buf. set selects GET(false)/SET(true).
func rawIoctl(ifname string, cmd uint32, buf []byte, set bool) error {
	fd, err := syscall.Socket(syscall.AF_INET, syscall.SOCK_DGRAM, 0)
	if err != nil {
		return fmt.Errorf("socket: %w", err)
	}
	defer syscall.Close(fd)

	ioc := wlIoctl{cmd: cmd, length: uint32(len(buf))}
	if len(buf) > 0 {
		ioc.buf = uintptr(unsafe.Pointer(&buf[0]))
	}
	if set {
		ioc.set = 1
	}

	var ifr ifreq
	copy(ifr.name[:15], ifname)
	*(*uintptr)(unsafe.Pointer(&ifr.union[0])) = uintptr(unsafe.Pointer(&ioc))

	e := ioctl(fd, siocDevPrivate, unsafe.Pointer(&ifr))
	// keep the Go-owned buffers reachable across the syscall (their addresses live in
	// uintptr fields the GC cannot see).
	runtime.KeepAlive(buf)
	runtime.KeepAlive(&ioc)
	runtime.KeepAlive(&ifr)
	if e != 0 {
		return fmt.Errorf("ioctl cmd=%d on %s: %w", cmd, ifname, e)
	}
	return nil
}

// iovarGet writes the NUL-terminated iovar name into a scratch buffer and reads the
// driver's reply back over it (WLC_GET_VAR).
func iovarGet(ifname, iovar string, outLen int) ([]byte, error) {
	if outLen < 256 {
		outLen = 256
	}
	buf := make([]byte, outLen)
	copy(buf, iovar)
	buf[len(iovar)] = 0
	if err := rawIoctl(ifname, wlcGetVar, buf, false); err != nil {
		return nil, err
	}
	return buf, nil
}

func iovarGetInt(ifname, iovar string) (int32, error) {
	b, err := iovarGet(ifname, iovar, 256)
	if err != nil {
		return 0, err
	}
	return int32(binary.LittleEndian.Uint32(b[:4])), nil
}

// SSID returns the BSS/radio SSID (WLC_GET_SSID 25).
func SSID(ifname string) (string, error) {
	buf := make([]byte, 4+maxSSID)
	if err := rawIoctl(ifname, wlcGetSSID, buf, false); err != nil {
		return "", err
	}
	n := binary.LittleEndian.Uint32(buf[:4])
	if n > maxSSID {
		n = maxSSID
	}
	return string(buf[4 : 4+n]), nil
}

// BSSID returns the BSSID (WLC_GET_BSSID 23) as AA:BB:.. uppercase.
func BSSID(ifname string) (string, error) {
	buf := make([]byte, 6)
	if err := rawIoctl(ifname, wlcGetBSSID, buf, false); err != nil {
		return "", err
	}
	return fmt.Sprintf("%02X:%02X:%02X:%02X:%02X:%02X",
		buf[0], buf[1], buf[2], buf[3], buf[4], buf[5]), nil
}

// Chanspec returns the 16-bit chanspec (iovar "chanspec").
func Chanspec(ifname string) (uint16, error) {
	v, err := iovarGetInt(ifname, "chanspec")
	return uint16(v & 0xffff), err
}

// BSSEnabled returns the BSS up-state (iovar "bss"; 1 = up).
func BSSEnabled(ifname string) (bool, error) {
	v, err := iovarGetInt(ifname, "bss")
	return v == 1, err
}

// AssocList returns the associated station MACs (WLC_GET_ASSOCLIST 159).
func AssocList(ifname string) ([]string, error) {
	const bufLen = 4096
	buf := make([]byte, bufLen)
	binary.LittleEndian.PutUint32(buf[:4], (bufLen-4)/6) // max entries the buffer can hold
	if err := rawIoctl(ifname, wlcGetAssocList, buf, false); err != nil {
		return nil, err
	}
	count := binary.LittleEndian.Uint32(buf[:4])
	macs := make([]string, 0, count)
	for i := uint32(0); i < count; i++ {
		o := buf[4+i*6:]
		if int(4+i*6+6) > len(buf) {
			break
		}
		macs = append(macs, fmt.Sprintf("%02X:%02X:%02X:%02X:%02X:%02X",
			o[0], o[1], o[2], o[3], o[4], o[5]))
	}
	return macs, nil
}

// GetVar is the generic iovar probe (returns the raw reply buffer).
func GetVar(ifname, iovar string) ([]byte, error) { return iovarGet(ifname, iovar, 4096) }

// ---- layout-trivial SET verbs (mirror the proven direct-WiFi recipe) --------

// SetSSID sets the BSS SSID (WLC_SET_SSID 26). NB: on a hostapd-managed BSS hostapd
// re-asserts its own SSID; use this only on a driver-owned (wl-only) BSS.
func SetSSID(ifname, ssid string) error {
	if len(ssid) > maxSSID {
		return fmt.Errorf("ssid too long")
	}
	buf := make([]byte, 4+maxSSID)
	binary.LittleEndian.PutUint32(buf[:4], uint32(len(ssid)))
	copy(buf[4:], ssid)
	return rawIoctl(ifname, wlcSetSSID, buf, true)
}

// SetBSS brings a BSS up(true)/down(false) via the "bss" iovar (set).
func SetBSS(ifname string, up bool) error {
	// iovar set: name\0 + int value
	val := uint32(0)
	if up {
		val = 1
	}
	buf := make([]byte, 4+4)
	copy(buf, "bss")
	binary.LittleEndian.PutUint32(buf[4:], val) // value follows the (short) name
	return rawIoctl(ifname, wlcSetVar, buf, true)
}

// RemoveInterface removes a runtime-created vif (iovar "interface_remove"). The matching
// interface_create needs the versioned wl_interface_create struct (driver wlc_ver 9 here)
// and is left to a follow-up; for now creation stays in netctl via stock `wl`.
func RemoveInterface(ifname string) error {
	buf := make([]byte, 256)
	copy(buf, "interface_remove")
	return rawIoctl(ifname, wlcSetVar, buf, true)
}
