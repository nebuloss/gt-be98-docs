# WPA-Enterprise / 802.1X — direct, open authenticator (verified)

> **VERIFIED LIVE 2026-06-05** on the GT-BE98 (BCM6813, impl105, sw_mode=3 AP). A
> **WPA-Enterprise (802.1X/EAP)** BSS can be created entirely from open tools
> (`wl interface_create` + `hostapd -B`) with **zero** ASUS orchestration, advertising the
> `WPA-EAP` / `WPA-EAP-SHA256` AKMs and pointing at a RADIUS **we** control. This is the
> enterprise counterpart of [`webui-direct-wifi.md`](webui-direct-wifi.md) (WPA2/WPA3-SAE).

## Result (authenticator side) [V]

Disposable 6 GHz vif `wl2.2` (`wl -i wl2 interface_create ap`), a separate per-BSS
`hostapd -B` coexisting with the radio's primary hostapd; siblings (`wl2.1`/test) unaffected:

```
state=ENABLED   freq=5955 (6g ch1)   ssid=re-ent6
wl -i wl2.2 wpa_auth  ->  0x1040  WPA2-802.1x 1X-SHA256
wl -i wl2.2 wsec      ->  68 (0x44 = CCMP + MFP)
txbcnfrm: +29/3s  (beaconing)
RADIUS Authentication server 127.0.0.1:1812   (the RADIUS we control)
```

### `wl wpa_auth` AKM bits — enterprise (observed live)

| `wpa_auth` | AKM | meaning |
|---|---|---|
| `0x40` | WPA-EAP | WPA2-Enterprise (802.1X, SHA1) — what stock **DEV-SCEP** uses |
| `0x1000` | WPA-EAP-SHA256 | 802.1X-SHA256 (WPA3-Enterprise basis) |
| `0x1040` | WPA-EAP + WPA-EAP-SHA256 | both offered (what `re-ent6` advertised on 6 GHz) |

(Compare the personal AKMs in `webui-direct-wifi.md`: `0x80` WPA2-PSK, `0x40000` SAE.)

## The verified conf — external RADIUS (the product path) [V]

```
driver=nl80211
ctrl_interface=/var/run/hostapd
interface=wl2.2
ssid=re-ent6
hw_mode=a
channel=1                 # 6g ch1 (match radio; 5950+5·N MHz). 2.4/5 GHz: hw_mode=g/a, matching channel
country_code=E0
ieee80211d=1
ieee80211h=1
ieee80211be=1
auth_algs=1
wpa=2
wpa_key_mgmt=WPA-EAP WPA-EAP-SHA256    # drop SHA256 for plain WPA2-Enterprise (2.4/5 GHz)
rsn_pairwise=CCMP
ieee80211w=2              # MFP required on 6 GHz; =0/1 fine on 2.4/5 GHz (DEV-SCEP uses 0)
ieee8021x=1
auth_server_addr=127.0.0.1
auth_server_port=1812
auth_server_shared_secret=re-radius-secret
# optional accounting:  acct_server_addr=127.0.0.1  acct_server_port=1813  acct_server_shared_secret=...
```

`hostapd -B -t -f /tmp/re-ent.log /tmp/re-ent.conf` → `AP-ENABLED`, beaconing, RADIUS
client configured. Teardown (order matters): `kill -9 <hostapd>` → `wl bss down` →
`brctl delif` (if bridged) → `wl interface_remove`.

The `127.0.0.1:1812` target is **`gt-be98-webui-go/internal/radsrv`** — webui-go's built-in
RADIUS, which already speaks EAP/MSCHAPv2/TLS. So the open enterprise stack is:
`wl`+`hostapd` (authenticator) → loopback RADIUS (`radsrv`, our code). No ASUS daemon
involved.

## Finding — hostapd's integrated EAP server here is **WPS-only** (option (a) is NOT viable) [V]

The brief's simplest option was hostapd's integrated EAP server (`eap_server=1` +
`eap_user_file`, e.g. an EAP-PEAP/MSCHAPV2 user). **On this build that does not work:** the
hostapd EAP *server* was compiled with only the **WSC (WPS)** method. Probed live by feeding
one method per `eap_user_file` and watching for `Unsupported EAP type`:

```
TLS PEAP TTLS GTC PWD TNC FAST TEAP PSK AKA SIM MD5 MSCHAPV2  -> all "Unsupported EAP type"
WSC                                                            -> state=ENABLED (WPS only)
```

So you **cannot** run a self-contained PEAP/TTLS/TLS RADIUS inside this on-box hostapd.
Real EAP auth must go to an **external** RADIUS (option (b)) — which is exactly what the
product does and what webui-go's `radsrv` provides. (`openssl` *is* on-box at
`/usr/sbin/openssl`, so certs can be generated for `radsrv`'s TLS methods — the cert work
belongs in `radsrv`, not in hostapd here.)

## Live corroboration — stock DEV-SCEP is external-RADIUS WPA-Enterprise [V]

The standing user net **DEV-SCEP** (the brief's hint that enterprise is a real target) is
WPA-Enterprise on all three of its bands, external RADIUS on the LAN:

```
wl0.1 / wl1.1 / wl3.2:  wpa_auth=0x40 WPA2-802.1x   ssid=DEV-SCEP
/tmp/wl0_hapd.conf (DEV-SCEP bss):
  wpa=2  wpa_key_mgmt=WPA-EAP  wpa_pairwise=CCMP  ieee80211w=0  ieee8021x=1
  auth_server_addr=10.0.0.6  auth_server_port=1812  auth_server_shared_secret=fWA+…qKo=
```

`re-ent6` reproduced this exactly (plus `WPA-EAP-SHA256`/MFP for 6 GHz), from open tools only.

## On-box client testing is NOT possible — authenticator-side is the proof [V]

A full EAP handshake needs a supplicant (RADIUS/EAP client). This router has **none usable**:

- `wpa_supplicant` is **v0.6.10**, drivers `wired`/`roboswitch` only — no `nl80211`, no
  modern EAP WiFi station.
- **No `eapol_test`, no `radclient`/`radtest`, no FreeRADIUS** on-box.
- An on-box STA vif shares its radio's channel (can't tune to a test AP).

The RADIUS round-trip is also un-triggerable on-box: hostapd only emits an Access-Request
when a real STA starts EAPOL over the air. So the verified deliverable is the **authenticator**:
the BSS advertises 802.1X (`wl wpa_auth` = `WPA-EAP`/`WPA-EAP-SHA256`), beacons, and is wired
to a RADIUS we control. End-to-end EAP is validated with a real client + `radsrv` (webui-go).

## Safety / footprint

Pure-runtime (vif + separate hostapd, no nvram, no `restart_wireless`) — auto-reverts on
reboot. Disposable footprint: radio `wl2`, SSID `re-*`. Always `kill -9` the test hostapd
(SIGTERM can leave it owning `/var/run/hostapd/<bss>`, blocking the next bind) and
`interface_remove` the vif; the 4 user nets stayed `isup=1` throughout.
