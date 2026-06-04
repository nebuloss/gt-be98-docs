# Plan — Fix save_network: remove Gateway IP + masked password on edit

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

## Verification

1. Deploy: `bash deploy/push.sh admin@10.0.0.8 2222`
2. **Edit**: open a network's modal → the password field shows dots (masked)
3. **Without changing the password**: click Save → success, password unchanged
4. **Change the password**: enter a new password → updated
5. **New network**: create without a password → "Mot de passe minimum 8 caractères"
6. **UI**: no more Gateway/DHCP column in the table, no more IP field in the modal
