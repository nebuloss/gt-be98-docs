# UI Architecture — Technical decisions

## Major discovery — direct hostapd

The user already drives hostapd directly via `/jffs/scripts/services-start`.
The Asus pipeline (nvram → wlconf → hostapd) is bypassed.

**Source of truth**: `/jffs/scripts/services-start`
**Apply**: rewrite `/tmp/wlX_hapd.conf` + `killall hostapd && hostapd ... -B`

→ See `hostapd_schema.md` for the full detail.

## Chosen stack

**lighttpd (already present) + CGI shell scripts + vanilla HTML/JS**

- Zero dependencies to cross-compile
- lighttpd 1.4.39 is already in the firmware
- CGI shell = direct access to nvram, wlconf, service
- vanilla HTML/JS = no framework, works on any browser

## Deployment

```
/jffs/webui/
  www/
    index.html          main page
    app.js              frontend logic
    style.css           styles
  cgi-bin/
    api.sh              single API endpoint (JSON)
  lighttpd.conf         server config
  start.sh              startup script
```

Startup at boot via `/jffs/scripts/post-mount`:
```sh
/jffs/webui/start.sh &
```

## CGI API — Frontend ↔ backend interface

Single endpoint: `GET/POST http://10.0.0.8:8080/cgi-bin/api.sh`

`action` parameter:

| action | method | description |
|---|---|---|
| `list_networks` | GET | parse services-start → list networks |
| `list_clients` | GET | `hostapd_cli all_sta` per interface |
| `get_radios` | GET | channels, status from active hapd.conf |
| `save_network` | POST | create/modify → rewrite services-start + hapd.conf + reload hostapd |
| `delete_network` | POST | same for deletion |

## Response format (JSON)

```json
{
  "ok": true,
  "data": { ... }
}
```

On error:
```json
{
  "ok": false,
  "error": "error message"
}
```

## Data model — Network

```json
{
  "slot": 1,
  "vlan": 20,
  "ssid": "NetA",
  "password": "••••••••",
  "security": "psk2sae",
  "radios": ["wl0", "wl1", "wl2", "wl3"],
  "bridge": "br20",
  "ip": "",
  "dhcp": false,
  "dhcp_start": "",
  "dhcp_end": "",
  "ap_isolate": false,
  "hidden": false
}
```

## UI pages

### Main page: network list
- Table: SSID | VLAN | Security | Radios | Clients | Actions
- "Add a network" button
- Status indicator (online / offline)

### Modal: Add/Edit a network
- SSID (text)
- Password (masked text)
- VLAN ID (numeric 1–4094)
- Gateway IP (optional)
- DHCP (toggle + range)
- Security (select: WPA2 / WPA3 / WPA2+WPA3)
- Active radios (checkboxes: 2.4G / 5G-1 / 5G-2 / 6G)
- Client isolation (toggle)
- Hidden SSID (toggle)

### Clients section (expandable per network)
- MAC | Hostname | IP | RSSI | Band

## Constraints

1. **Max 7 networks** (slots .1 to .7) by Asus convention, in practice 4-5 stable
2. **restart_wireless cuts ~5s** of Wi-Fi — warn the user before apply
3. **nvram commit** slow (~1s) — do it only once after all the sets
4. **current br20 without IP** — the UI must detect it and offer the fix
5. **Authentication**: gate by password + session cookie.
   - Password hashed (sha256 + salt) in `/jffs/webui/auth.conf` (chmod 600)
   - Sessions (random 128-bit token + timestamp) in `/tmp/webui-sessions`, TTL 24 h
   - First launch: if no password, the UI forces a creation screen;
     the API stays open as long as no password is defined
   - `api.sh` refuses any action (except `auth_status`/`login`/`logout`) without a valid
     session; static files (html/js/css, with no secret) remain public
   - `httpd.sh` passes the `Cookie` header to the CGI via `HTTP_COOKIE`
   - Actions: `auth_status`, `login`, `logout`, `set_password`
