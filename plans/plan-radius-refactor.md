# Plan — RADIUS refactoring: dedicated section + network↔server mapping

## Context

Currently the RADIUS parameters (IP, port, secret) are entered directly
in the create/edit modal of a WiFi network. This is not convenient if
several Enterprise networks share the same RADIUS server.

**New model (UniFi style)**:
1. "RADIUS Servers" section in the UI — manage RADIUS servers independently
2. In the Enterprise WiFi modal — choose a RADIUS server among those configured

---

## Data architecture

### New file: `/jffs/webui/radius_servers.conf`
```
RS_1_NAME=FreeRADIUS-Prod
RS_1_IP=192.168.1.10
RS_1_PORT=1812
RS_1_SECRET=mysecret
RS_1_BACKUP_IP=
RS_1_NAS_ID=

RS_2_NAME=WindowsNPS
RS_2_IP=10.0.0.20
RS_2_PORT=1812
RS_2_SECRET=secret2
RS_2_BACKUP_IP=10.0.0.21
RS_2_NAS_ID=ap1
```

### Change in `networks.conf`
Replace the `RADIUS_IP/PORT/SECRET/RADIUS2_IP/NAS_ID` fields with:
```
NET_<id>_RADIUS_SERVER=1   ← RADIUS server ID
```

---

## Implementation

### 1. `src/cgi-bin/api.sh` — New RADIUS server CRUD actions

```bash
RADIUS_SERVERS_CONF="/jffs/webui/radius_servers.conf"

action_get_radius_servers()    # list without secrets
action_add_radius_server()     # name, ip, port, secret, backup_ip, nas_id
action_delete_radius_server()  # by id
action_update_radius_server()  # modify (optional secret = keep existing)
```

`action_save_network`: replace the 5 RADIUS params with `radius_server` (id).
Validation: if enterprise/wpa3enterprise → radius_server required and existing.

### 2. `src/cgi-bin/lib/networks.sh`

**New helper `rs_get <id> <key>`** to read from radius_servers.conf.

**`net_to_json`**: return `radius_server_id` + `radius_server_name` (without secret).

**`net_apply_all`** and **`net_write_services_start`**:
- Read the network's `RADIUS_SERVER` id
- Call `rs_get` to retrieve IP/port/secret/backup/nas_id
- Pass these values to `upsert_bss`

### 3. `src/www/index.html`

**New "RADIUS Servers" section** (between Port Forwarding and Static DHCP):
```html
<section>
  <div class="section-header">
    <div class="section-title">Serveurs RADIUS</div>
    <button class="btn-primary" id="btn-add-radius">+ Ajouter</button>
  </div>
  <div class="panel-wrap" id="radius-servers-wrap">...</div>
</section>
```

**RADIUS server add modal**:
- Name (free label)
- IP / Hostname
- Port (default 1812)
- Shared Secret (type=password)
- Backup server (optional)
- NAS Identifier (optional)

**Network modal — Enterprise section**:
Replace the `#radius-fields` block (5 inputs) with a simple select:
```html
<div id="radius-server-select" style="display:none">
  <label>Serveur RADIUS</label>
  <select id="field-radius-server">
    <option value="">-- Choisir un serveur --</option>
    <!-- populated dynamically -->
  </select>
  <a class="form-hint" href="#radius-servers">Gérer les serveurs RADIUS ↗</a>
</div>
```

### 4. `src/www/app.js`

**New state**: `let radiusServers = [];`

**New functions**:
- `renderRadiusServers()` — lists the servers in the dedicated section
- `deleteRadiusServer(id)` — with confirmation
- Event handlers for the server add modal

**`updateSecurityUI()`**: instead of showing `#radius-fields`, show `#radius-server-select` and populate the `<select>` from `radiusServers`.

**`openEdit()`**: pre-select the correct RADIUS server in the dropdown.

**`loadAll()`**: add `api('get_radius_servers')` to the `Promise.all`.

---

## Modified files

| File | Change |
|---|---|
| `src/cgi-bin/api.sh` | +get/add/delete/update_radius_server ; save_network : radius_server id |
| `src/cgi-bin/lib/networks.sh` | +rs_get helper ; net_to_json/apply_all/services-start via RS id |
| `src/www/index.html` | +RADIUS Servers section + modal ; network modal: select instead of 5 inputs |
| `src/www/app.js` | renderRadiusServers, updateSecurityUI, openEdit, loadAll |
| `src/www/style.css` | Reuses existing `.panel-wrap/.panel-row` — few changes |

---

## Verification

1. Deploy: `bash deploy/push.sh admin@10.0.0.8 2222`
2. Add a RADIUS server "FreeRADIUS-Test" via the dedicated section
3. Create a WPA2-Enterprise network on VLAN 50 — the dropdown offers "FreeRADIUS-Test"
4. Check `/tmp/wlX_hapd.conf`: `auth_server_addr`, `ieee8021x=1` correct
5. Delete the RADIUS server → verify an error message if used by a network
