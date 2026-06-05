// gowl — CLI front-end over the gowl package, mirroring the C `owl` commands so it can be
// diffed byte-for-byte against stock `wl` / `owl` on the AP.
//
//	gowl <ifname> ssid|bssid|chanspec|bss_enabled|assoclist|getvar <name>
//
// Build (router 32-bit ARM, static, no libc):
//
//	GOARCH=arm GOARM=7 CGO_ENABLED=0 go build -ldflags "-s -w" -o gowl ./cmd/gowl
package main

import (
	"encoding/hex"
	"fmt"
	"os"

	"gtbe98/gowl"
)

func main() {
	if len(os.Args) < 3 {
		fmt.Fprintln(os.Stderr, "usage: gowl <ifname> ssid|bssid|chanspec|bss_enabled|assoclist|getvar <name>")
		os.Exit(2)
	}
	ifn, cmd := os.Args[1], os.Args[2]
	var err error
	switch cmd {
	case "ssid":
		var s string
		if s, err = gowl.SSID(ifn); err == nil {
			fmt.Println(s)
		}
	case "bssid":
		var s string
		if s, err = gowl.BSSID(ifn); err == nil {
			fmt.Println(s)
		}
	case "chanspec":
		var c uint16
		if c, err = gowl.Chanspec(ifn); err == nil {
			fmt.Printf("0x%04x\n", c)
		}
	case "bss_enabled":
		var up bool
		if up, err = gowl.BSSEnabled(ifn); err == nil {
			if up {
				fmt.Println("1")
			} else {
				fmt.Println("0")
			}
		}
	case "assoclist":
		var macs []string
		if macs, err = gowl.AssocList(ifn); err == nil {
			fmt.Printf("assoclist %d\n", len(macs))
			for _, m := range macs {
				fmt.Println(m)
			}
		}
	case "getvar":
		if len(os.Args) < 4 {
			fmt.Fprintln(os.Stderr, "getvar needs a name")
			os.Exit(2)
		}
		var b []byte
		if b, err = gowl.GetVar(ifn, os.Args[3]); err == nil {
			n := 16
			if len(b) < n {
				n = len(b)
			}
			fmt.Printf("bytes: %s\n", hex.EncodeToString(b[:n]))
		}
	default:
		fmt.Fprintf(os.Stderr, "unknown command: %s\n", cmd)
		os.Exit(2)
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "gowl:", err)
		os.Exit(1)
	}
}
