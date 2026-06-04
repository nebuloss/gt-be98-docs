# Plan — WPA Enterprise (802.1X/RADIUS) on the GT-BE98

## Capabilities verified on the hardware

### hostapd v2.10 — natively supports:
| Mode | wpa_key_mgmt | Notes |
|---|---|---|
| WPA2-Enterprise | `WPA-EAP` | Authentication via external RADIUS |
| WPA2-Enterprise SHA256 | `WPA-EAP-SHA256` | More secure |
| WPA3-Enterprise 128-bit | `WPA-EAP-SUITE-B` | Suite B |
| WPA3-Enterprise 192-bit | `WPA-EAP-SUITE-B-192` | NSA Suite B |

**Role of the AP**: 802.1X authenticator only — it relays EAP frames to an
external RADIUS server. **All EAP types are supported** (PEAP, EAP-TLS, EAP-TTLS,
EAP-MSCHAPv2…) because hostapd passes them to RADIUS without interpreting them.

**No built-in EAP server** — an external RADIUS is required (FreeRADIUS, Windows NPS,
Cisco ISE, pfSense, etc.).

### nvram — RADIUS variables already present per BSS:
```
wl0.1_radius_ipaddr   = ""        ← primary server
wl0.1_radius_port     = 1812
wl0.1_radius_key      = ""        ← shared secret
wl0.1_radius2_ipaddr  = ""        ← backup server
wl0.1_radius2_port    = 1812
wl0.1_radius2_key     = ""
wl0.1_radius_acct_ipaddr = ""     ← accounting (optional)
wl0.1_radius_acct_port   = 1813
wl0.1_radius_acct_key    = ""
```

### Limitations:
- **6 GHz (wl2)**: WPA-Enterprise not supported — the standard mandates SAE (WPA3-SAE) on 6 GHz
- **No captive portal / MAC bypass** via this approach (pure 802.1X only)

---

## Usage context

802.1X tests with **certificates issued by a SCEP server**:
- The external RADIUS validates client certificates (EAP-TLS)
- Certificates are issued automatically by SCEP (e.g. EJBCA, NDES, OpenXPKI)
- The AP is purely an authenticator — it passes EAP frames to RADIUS without interpreting the certificates

---

## Implementation plan

### 1. `src/cgi-bin/lib/hapd_gen.sh` — `gen_bss_block`

Add the extended signature to pass the RADIUS parameters:
```bash
# gen_bss_block <radio> <slot> <ssid> <password> <security> <vlan> <isolate> <hidden>
#               [radius_ip] [radius_port] [radius_secret] [radius2_ip] [nas_id]
```

New cases `enterprise` (WPA2-Enterprise) and `wpa3enterprise` (WPA3-Enterprise):
```bash
enterprise)
    printf "auth_algs=1\n"
    printf "wpa=2\n"
    printf "wpa_key_mgmt=WPA-EAP\n"
    printf "wpa_pairwise=CCMP\n"
    printf "ieee8021x=1\n"
    printf "auth_server_addr=%s\n" "$radius_ip"
    printf "auth_server_port=%s\n" "${radius_port:-1812}"
    printf "auth_server_shared_secret=%s\n" "$radius_secret"
    [ -n "$radius2_ip" ] && printf "auth_server_addr_replace=%s\n" "$radius2_ip"
    [ -n "$nas_id" ]     && printf "nas_identifier=%s\n" "$nas_id"
    printf "ieee80211w=1\n"
    ;;
wpa3enterprise)
    printf "wpa_key_mgmt=WPA-EAP-SHA256\n"
    printf "ieee80211w=2\n"
    # same ieee8021x + auth_server...
    ;;
```

### 2. `src/cgi-bin/lib/networks.sh`

Add the new fields in `net_to_json`, `net_apply_all`, `net_write_services_start`:
- `RADIUS_IP`, `RADIUS_PORT`, `RADIUS_SECRET`
- `RADIUS2_IP` (optional)
- `NAS_ID` (optional, default = SSID)

### 3. `src/cgi-bin/api.sh` — `action_save_network`

Parse the new RADIUS parameters and validate them:
- `radius_ip` required if security == enterprise/wpa3enterprise
- `radius_secret` required

### 4. `src/www/index.html` — network modal

```html
<!-- Add to the security select -->
<option value="enterprise">WPA2-Enterprise (802.1X)</option>
<option value="wpa3enterprise">WPA3-Enterprise (802.1X)</option>

<!-- Conditional RADIUS block (visible if enterprise selected) -->
<div id="radius-fields" style="display:none">
  <input id="field-radius-ip"     placeholder="192.168.1.10">
  <input id="field-radius-port"   value="1812">
  <input id="field-radius-secret" type="password">
  <input id="field-radius2-ip"    placeholder="Serveur backup (optionnel)">
  <input id="field-nas-id"        placeholder="NAS identifier (optionnel)">
</div>
```

### 5. `src/www/app.js`

- Show/hide `#radius-fields` according to the chosen security
- Include the RADIUS fields in the POST
- In `renderNetworks()`: show a "802.1X" badge in place of the password

---

## Modified files

| File | Change |
|---|---|
| `src/cgi-bin/lib/hapd_gen.sh` | New cases `enterprise` + `wpa3enterprise` in `gen_bss_block` |
| `src/cgi-bin/lib/networks.sh` | RADIUS fields in net_to_json / net_apply_all / services-start |
| `src/cgi-bin/api.sh` | Parse + validate RADIUS params in save_network |
| `src/www/index.html` | Enterprise options in select + conditional RADIUS block |
| `src/www/app.js` | Show/hide RADIUS fields + openEdit + form submit |

---

## Verification

1. Deploy: `bash deploy/push.sh admin@10.0.0.8 2222`
2. Create a WPA2-Enterprise network with RADIUS IP 192.168.x.x
3. Check in `/tmp/wlX_hapd.conf`: presence of `ieee8021x=1`, `auth_server_addr`, `wpa_key_mgmt=WPA-EAP`
4. Test a client connection with RADIUS certificate/identity
5. 6GHz (wl2): the enterprise select must be disabled or absent
