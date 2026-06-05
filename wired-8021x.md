# Wired 802.1X authenticator on the LAN ports — feasibility

> Question: can the GT-BE98 act as a **wired 802.1X authenticator** — force devices
> plugged into its ethernet (LAN) ports to authenticate via EAP to an (external)
> RADIUS before getting network access (IEEE 802.1X port-based access control on a
> copper port)?
>
> **Verdict: NO with the stock firmware. PARTIAL / buildable in principle** — but
> end-to-end enforcement on this Broadcom SoC is *unproven* and faces a hardware
> fast-path obstacle. See caveats.
>
> Claims marked **[V]** = verified live / cross-validated against a live observation;
> **[P]** = inferred from firmware source.

This is the **wired** counterpart of [`wifi-enterprise.md`](wifi-enterprise.md) (which
verified a *WiFi* 802.1X authenticator from open tools). Wired is a different story.

## Assessment was read-only (source) this session

The live device (`ssh -p 2222 admin@…`) was **unreachable** during this assessment
(connection timeouts the whole session — another agent's work / reboot). No ports were
touched. The verdict rests on the firmware **source tree**
(`gt-be98-firmware/vendor/asuswrt-merlin.ng`, impl105 = our BCM6813 wl driver), which is
**cross-validated** against a prior live observation (see hostapd EAP-server fingerprint
below) — so the source reliably reflects the on-device binaries.

## 1. Stock hostapd has NO wired driver [P, cross-validated]

The on-device hostapd is built from
`…/wl/impl105/main/components/opensource/router_tools/hostapd/hostapd/brcm.config`,
copied verbatim to `.config` by the router Makefile (no post-processing):

```
release/src/router/Makefile:7343
$(HOSTAPD_DIR)/hostapd/.config: $(HOSTAPD_DIR)/hostapd/brcm.config
	cp $(HOSTAPD_DIR)/hostapd/brcm.config $(HOSTAPD_DIR)/hostapd/.config;
```

In `brcm.config` the wired-authenticator driver is **commented out**:

```
# Driver interface for wired authenticator
#CONFIG_DRIVER_WIRED=y          <-- DISABLED
CONFIG_DRIVER_NL80211=y
CONFIG_DRIVER_BRCM=y            (+ BRCM MAP/MLO/RDKB variants)
CONFIG_DRIVER_NONE=y
```

So the stock `hostapd` advertises `nl80211` / `brcm` / `none` only. Feeding it
`driver=wired` would be rejected ("Unsupported driver 'wired'"). The driver *source*
(`src/drivers/driver_wired.c`) is present in-tree but **not compiled in**.

**Cross-validation that `brcm.config` == the live binary** [V]: the same `brcm.config`
has *every* EAP-server method commented out and only `CONFIG_WPS=y` enabled
(`#CONFIG_EAP_TLS`, `#CONFIG_EAP_PEAP`, `#CONFIG_EAP_TTLS`, … `#CONFIG_RADIUS_SERVER`
all off). That is exactly the **WPS-only EAP server** fingerprint that
[`wifi-enterprise.md`](wifi-enterprise.md) confirmed *live* (every EAP type returned
"Unsupported EAP type" except WSC). Matching that live fingerprint to this file is strong
evidence the file is the real build config — hence the commented `CONFIG_DRIVER_WIRED`
reliably reflects the shipped binary.

(The RADIUS **client** plumbing — `auth_server_addr` — *is* built in; that is how the WiFi
802.1X authenticator forwards EAP to an external RADIUS. So only the wired *driver* is
missing, not the RADIUS-client path.)

## 2. ASUSWRT ships only the WAN-side wired *supplicant*, no LAN authenticator [P]

Grepping the router source for a wired authenticator finds only **`wpa_supplicant`'s**
`driver_wired.c` — i.e. the device acting as an 802.1X *supplicant* (client) on its WAN
uplink, never as an authenticator gating a LAN port. There is no nvram key, rc script, or
GUI surface for wired port authentication. The enterprise feature ASUS ships is
*WiFi*-only (e.g. the `DEV-SCEP` WPA-Enterprise SSID, external RADIUS — see
`wifi-enterprise.md`).

## 3. The Broadcom switch exposes NO 802.1X / per-port auth [P]

`ethswctl` (the switch control tool) has **no** authentication verb. Its full command set
is QoS / VLAN / mirroring / rate-limit / link plumbing. The only port gating it offers is
**whole-port** admin up/down:

```
ethswctl -c portctrl  -i <if> -v <0|1>          # disable/enable an entire port
ethswctl -c setlinkstatus …                      # force link state
ethswctl -c hw-switching -o <enable|disable>     # toggle HW switching
… mibdump / pause / phymode / rxratectrl / cosq… (no auth, no dot1x, no MAC-auth)
```

There is **no** per-supplicant / EAP-driven / MAC-authentication primitive in the switch.
(The SoC *does* have a MACsec/802.1AE-capable PHY — `bcmdrivers/opensource/phy/xflow`,
`xflow_macsec*` — but MACsec is point-to-point link encryption for trunks, **not**
802.1X host port-authentication; it does not solve this.)

The Linux side is a standard bridge (`br0`) over the four port netdevs, plus `ebtables`
(`CONFIG_BRIDGE_EBT_*=y`). There is no native kernel "802.1X controlled port" — ebtables
could crudely allow/deny by MAC, but that is static MAC filtering, not EAP.

## 4. Port topology (the lockout hazard)

The 4 LAN ports are **separate Linux netdevs** `eth0 eth1 eth2 eth3`, bridged under `br0`.
The admin/SSH path arrives over ethernet on one of them. Any port-blocking enforcement on
the admin port or on `br0` would sever SSH, and there is **no serial console** →
unrecoverable. (Live carrier/MAC mapping to identify the exact admin port could not be
captured this session because the device was unreachable; do this before any Phase B.)

## Verdict + what it would take

**Stock firmware: NO.** No wired authenticator binary, no firmware feature, no switch
primitive.

**PARTIAL / buildable** (we own the firmware/buildroot build), if a future need arises:

1. **Rebuild hostapd with `CONFIG_DRIVER_WIRED=y`** (uncomment it in `brcm.config`).
   `driver_wired.c` is already in-tree; the RADIUS-client path is already compiled. This
   produces a `hostapd` that accepts `driver=wired ieee8021x=1` and forwards EAP to an
   external RADIUS (`auth_server_addr=…`), e.g. webui-go's `radsrv` — same external-RADIUS
   wiring proven for WiFi in `wifi-enterprise.md`.
2. **Run it on a dedicated LAN port netdev** (e.g. `eth3`) that is **not** in the
   unauthenticated data path of `br0`. hostapd's wired authenticator gates by listening
   for EAPOL on the interface and marking it authorized/unauthorized.
3. **‼️ Unproven obstacle — Broadcom hardware fast-path [P].** This is 5.04behnd with the
   Runner/Archer flow accelerator and hardware switching (`ethswctl -c hw-switching`).
   Inter-port L2 forwarding is typically **hardware-offloaded**, bypassing the CPU/bridge.
   A *software* EAPOL authenticator only reliably gates a port when **all** of that port's
   traffic traverses the Linux netdev. So enforcement would likely require disabling HW
   switching / flow-accel for that port and confirming frames actually reach the CPU —
   which sacrifices throughput and is **not verified to work** here. Until live-tested,
   end-to-end wired-port enforcement on this SoC should be treated as **unproven**.
4. **Never** enable this on the admin/uplink port or on `br0` (lockout, no serial recovery).

In short: the EAP/RADIUS *brain* is reproducible (rebuild one hostapd flag + reuse the
external-RADIUS wiring), but the **port-enforcement *muscle*** on a hardware-switched
Broadcom port is the real open question — the stock switch gives you only whole-port
on/off, and a software authenticator may be bypassed by the HW fast path. This is why the
verdict is *partial*, not *yes*.
