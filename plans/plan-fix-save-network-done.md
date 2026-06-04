# Plan — COMPLETED — Fix save_network: JSON end + Gateway IP + masked password

## Context

The GT-BE98 router is in AP/bridge mode (br20/br30 without IP, no NAT).
The "IP Gateway" field is therefore useless.

Two bugs + one UX improvement:
1. **Remove the Gateway IP field** (UI + API + networks.sh)
2. **Password on edit**: display the current password masked (dots `••••••••`)
   - Currently the field is empty when opening, and submitting without filling it overwrites the password
   - Fix: send the password from the API, display it masked in an `<input type="password">`, only update it if the user changes the value

---

## Bug 1 — Remove the Gateway IP field

### `src/cgi-bin/api.sh` — `action_save_network`
Remove `ip="$(param ip "$body")"` and `net_set "$id" IP "$ip"`.

### `src/cgi-bin/lib/networks.sh` — `net_apply_all`
Remove the `if [ -n "$ip" ]; then ip addr add ...; fi` block.

### `src/www/index.html`
Remove the `<div class="form-group">` containing `<input id="field-ip">` and the `<th>Gateway / DHCP</th>`.

### `src/www/app.js`
- Form submit: remove `ip: document.getElementById('field-ip').value`
- `openEdit`: remove `document.getElementById('field-ip').value = ...`
- `renderNetworks`: remove the `gwCell` variable and its `<td>` cell

---

## Bug 2 + UX — Password masked and preserved

### `src/cgi-bin/lib/networks.sh` — `net_to_json`

Include the password in the returned JSON (already read into the `pass` variable):

```bash
# Add "password" to the printf of net_to_json
printf '{"id":%d,...,"password":"%s",...}' \
    "$id" "$slot" "$ssid" "$vlan" "$security" "$pass" ...
```

### `src/www/index.html` — network modal

Change the password field from `type="text"` to `type="password"`:
```html
<input type="password" id="field-password" placeholder="min. 8 caractères" autocomplete="new-password">
```

### `src/www/app.js` — `openEdit`

Pre-fill with the real password (will be displayed masked):
```js
document.getElementById('field-password').value = net.password || '';
```

### `src/cgi-bin/api.sh` — `action_save_network` — password validation

For editing: only reject if the password is explicitly modified and too short.  
Always update the password (since it is now always sent from the form) — no need for the "empty = keep" logic.

```bash
# Validation unchanged (password is always supplied from the form)
[ "$security" != "open" ] && [ ${#pass} -lt 8 ] \
    && json_err "Mot de passe minimum 8 caractères" && return
```

Note: `net_set "$id" PASSWORD "$pass"` remains unchanged — the password is always sent.

---

## Modified files

| File | Change |
|---|---|
| `src/cgi-bin/api.sh` | Remove the `ip` param in save_network |
| `src/cgi-bin/lib/networks.sh` | Remove `ip addr add`; add `password` in `net_to_json` |
| `src/www/index.html` | Remove IP field + table column; `type="password"` on the password field |
| `src/www/app.js` | Remove ip field; pre-fill password in openEdit |

---

## Bug 3 — socat timeout (root cause of the "unexpected JSON end")

**Root cause**: `httpd.sh` used `cgi_out="$("$CGI_DIR/api.sh")"` (a `$()` pipe).  
Under busybox ash, `hostapd -B` forks a daemon that inherits an internal auxiliary fd of the busybox pipe (not fd 1 — undocumented). This fd stays open as long as hostapd is running → the `$()` command never receives EOF → 30s blockage until the socat timeout → connection cut → empty response → "Unexpected end of JSON".

**Fix**: replace `$()` with a temporary file in `src/httpd.sh`:

```sh
# Before
cgi_out="$("$CGI_DIR/api.sh")"
printf "HTTP/1.0 200 OK\r\n%s" "$cgi_out"

# After
local cgi_tmp="/tmp/webui-cgi-$$.tmp"
"$CGI_DIR/api.sh" > "$cgi_tmp"
printf "HTTP/1.0 200 OK\r\n"
cat "$cgi_tmp"
rm -f "$cgi_tmp"
```

With `> file`, the shell only waits for **api.sh** to finish (not its children).  
The hostapd daemon inherits the temp file's fd, not a pipe → no blockage.

**Other related changes**:
- `src/cgi-bin/lib/networks.sh`: `hostapd ... &` + `disown` + `</dev/null` to detach cleanly
- `src/service-event`: same thing
- `deploy/push.sh` + `services-start` template: socat `-T 30` → `-T 90` as a safety net

---

## UX — "Application in progress" banner during the hostapd restart

**Context**: `save_network` now returns in ~100ms, but hostapd restarts in the background (~3-4s). During that time Wi-Fi is down and the buttons must be disabled to avoid a double apply.

**Approach: server lock file + UI polling**

**`src/cgi-bin/api.sh`** — changes in `action_save_network`:
1. If `/tmp/webui-applying` already exists → `json_err "Application déjà en cours"` (avoids double apply)
2. After saving the config, create the lock BEFORE launching the background:
   ```sh
   echo "$(date)" > /tmp/webui-applying
   (
       . $LIB_DIR/networks.sh
       HAPD_CONFS="..."
       # upsert_bss + killall + sleep + hostapd & + services-start
       rm -f /tmp/webui-applying
   ) </dev/null >/tmp/webui-apply.log 2>&1 &
   json_ok "{\"id\":${id}}"
   ```
   Note: move the `upsert_bss + hostapd &` logic into the background subshell.

**New endpoint `get_apply_status`**:
```sh
action_get_apply_status() {
    if [ -f /tmp/webui-applying ]; then
        json_ok '{"applying":true}'
    else
        json_ok '{"applying":false}'
    fi
}
```

**`src/www/index.html`** — fixed banner at the bottom:
```html
<div class="task-banner" id="task-banner" style="display:none">
  <div class="task-spinner"></div>
  <span>Redémarrage Wi-Fi en cours — boutons désactivés</span>
</div>
```

**`src/www/app.js`**:
- `setApplying(bool)`: show/hide banner, disable/re-enable the network buttons
- After `api('save_network')` → `setApplying(true)` + poll `get_apply_status` every 2s
- When `applying=false` → `setApplying(false)` + `loadAll()`
- On page startup: check `get_apply_status` (in case a reboot was in progress from before)

**`src/www/style.css`** — banner + spinner CSS.

---

## Verification

1. Deploy: `bash deploy/push.sh admin@10.0.0.8 2222`
2. **Edit**: open a network's modal → the password field shows dots (masked)
3. **Without changing the password**: click Save → success, password unchanged
4. **Change the password**: enter a new password → updated
5. **New network**: create without a password → "Mot de passe minimum 8 caractères"
6. **UI**: no more Gateway/DHCP column in the table, no more IP field in the modal
