# SDN / mtlancfg Investigation — why the webui cannot own VLAN bridging

> Forensic report of a live investigation (2026-06-02) on the
> GT-BE98. Conclusion: **WiFi→VLAN bridging is locked inside the Asus
> firmware (`mtlancfg`/SDN) and can be neither replaced nor overridden from the outside.**
> This document exists to spare anyone from redoing these ~3h of tests.

> ✅ **UPDATE (2026-06-03) — MAINFH is RESOLVED.** The conclusion above
> ("neither replaced nor overridden **from the outside**") remains true for the
> runtime layer (`/jffs`). But we now **build the custom firmware**
> (`../gt-be98-firmware`) and have patched it at the source: patch `0025` makes
> `get_all_lanifnames_list()` (the OPEN function from which the closed hostapd generator pulls
> its BSS list) remove the ifaces in `nvram hapd_exclude_ifnames`. With
> `hapd_exclude_ifnames="wl3.1"`, MAINFH (`MyPrivateNetwork`) is no longer created at all
> (neither BSS nor bridge), at boot as at `restart_wireless` — validated live. The
> `ssid-suppressor`/`bridge-enforcer` watchdogs are **removed**. §10 (inoperative nvram
> levers) remains accurate: that is precisely why the firmware had to be patched.

---

## 1. Initial objective

Make the webui the sole driver of the network config and **restore NetA**
(multi-band SSID on VLAN 20), after observing that it no longer *beaconed*.
Starting hypothesis: "neutralize the Asus SDN and have the webui own the
bridging" (validated by the user before the constraints below were known).

---

## 2. Discovered architecture (SDN / Guest-Pro layer)

```
GUI/cfg_server  ──writes──>  common.json (desired config) + apg_ifnames_used.json (vif alloc)
                                   │
nvram: sdn_rl / vlan_rl / apg<N>_* / apg_brXX_fh_wlifnames
                                   │
        restart_wireless ──> mtlancfg ──> computes lanX_ifnames + creates brXX
                                   │
                            wl driver ──> bridges the wlX.* according to lanX_ifnames
```

Key pieces (observed values):
- `sdn_rl`: 0=DEFAULT, 1=MAINBH, 2=MAINFH, 3=Customized→apg3(NetB,vid30), 4=Customized→apg4(NetA,vid20)
- `vlan_rl=<1>30>0><2>20>0>` (only VLAN 30 and 20 exist)
- `apg_brXX_fh_wlifnames` = **front-haul** interfaces per bridge (`wl0.20 wl1.20 wl2.20 wl3.20`)
- `apg_ifnames_used.json` (`/jffs/.sys/cfg_mnt/`, perms `000`) = **slot allocation** per SDN:
  ```json
  {"vif_used":{"<redacted-mac>":[
     {"sdn_idx":"2","sdn_vid":"0", "sdn_band":[{"wl_ifname":"wl3.1"}]},  // MyPrivateNetwork → wl3.1
     {"sdn_idx":"3","sdn_vid":"30","sdn_band":[{"wl_ifname":"wl3.2"}]}   // NetB → wl3.2 (works)
  ]}}                                                                     // NO entry for NetA (sdn 4)
  ```

### Two types of WiFi interfaces (source of all the confusion)
- **BSS slot** `wlX.<1-4>`: *beacon* (`wl -i … isup` = 1). This is what a client sees.
- **Front-haul VLAN** `wlX.<vlan>` (e.g. `wl3.20`): **do not beacon** (`isup` empty);
  these are fabric interfaces, members of the bridge but silent.

A VLAN network only works if a **BSS slot** is bridged into `br<vlan>`.
NetB: `wl3.2` (slot) ∈ `br30` ✓. NetA: no slot bridged → silent.

---

## 3. The NetA case

- `common.json` wants NetA on `wl0.1/wl1.1/wl2.1/wl3.1` (all bands, password ok).
- **BUT** `apg_ifnames_used.json` gave `wl3.1` to MyPrivateNetwork (sdn 2) and
  **allocated NO slot to NetA** (sdn 4) → unresolved allocation conflict.
- Result: `mtlancfg` puts only the front-haul (`wl*.20`, silent) into `lan2_ifnames`.
  NetA beacons nowhere.

Key asymmetry: **NetB is single-band (2.4 GHz)** → `mtlancfg` allocates it a slot.
**NetA is multi-band** → `mtlancfg` allocates it only front-haul.

---

## 4. Everything that was tried — and why it fails

| # | Attempt | Result |
|---|---|---|
| 1 | `apg4_security` (was empty) ← valid blob | ✗ still silent |
| 2 | `apg4_macmode` `0`→`disabled` (match apg3) | ✗ |
| 3 | Disable MyPrivateNetwork (free `wl3.1`) | ✗ NetA still without a slot |
| 4 | `nvram set wl0.1_bss_enabled=1` + `wlconf wl0.1 up` (without restart_wireless) | ✗ the slot does not instantiate without restart_wireless |
| 5 | Same + `restart_wireless` | slot **beacons** but lands on **br0** (admin LAN) |
| 6 | Add `wl0.1` to `apg_br20_fh_wlifnames` | ✗ stays on br0 |
| 7 | Add `wl0.1` to `lan2_ifnames` (uncommitted) + restart_wireless | ✗ `mtlancfg` regenerates lan2 without wl0.1 |
| 8 | Same **committed** (+ remove wl0.1 from `lan_ifnames`) | ✗ `mtlancfg` **overwrites even committed values** |
| 9 | Edit/delete `apg_ifnames_used.json` | ✗ `restart_wireless` ignores it (cfg_server bookkeeping) |
| 10 | `service restart_cfgsync` (force re-allocation) | ✗ does not regenerate the allocation |
| 11 | Clear `vlan_rl` (neutralize the SDN) | ✗ **destroys br20/br30** — the SDN owns the bridges |
| 12 | Bridge a wl slot via `brctl addif` | ✗ "Operation not supported" (driver blocks) |

---

## 5. Final conclusion

1. **Only the `wl` driver can bridge a WiFi interface** — `brctl`/`ip link`
   return "Operation not supported" on the `wl*` (#12).
2. **This bridging is driven exclusively by `mtlancfg`**, which computes
   `lanX_ifnames` deterministically from the SDN config and **overwrites any
   value, committed or not** (#7, #8).
3. **The SDN also owns the VLAN bridges**: clearing `vlan_rl` destroys `br20/br30` (#11).
4. **Slot allocation is internal to `mtlancfg`/`cfg_server`** and exposes
   no effective external lever (#9, #10); it allocates a slot to the single-band
   (NetB) but not to the multi-band (NetA).

→ **"webui owns VLAN bridging" is IMPOSSIBLE on this firmware.** WiFi↔VLAN
bridging is locked inside `mtlancfg`/`cfg_server` (AiMesh layer).

---

## 6. Realistic scope of the webui (corrected)

| The webui CAN (fast, live) | The webui CANNOT |
|---|---|
| Override SSID (`wl … ssid`) | Create a VLAN / a bridge |
| Password (`hostapd_cli reload_wpa_psk`) | Bridge a WiFi slot into a VLAN |
| Security / hidden / isolation / channel | Reallocate SDN slots |
| Disable the Asus UI, SSH, port-fwd, static DHCP, RADIUS, monitoring | Decide which band/bridge a BSS lands on |

**VLAN/bridge provisioning** remains the responsibility of the Asus config
(`cfg_server`/GUI). The webui layers on top to manage SSID/password/security.

---

## 7. Recovery method used (reusable)

All risky work was done behind a **dead-man switch** (verified):
```sh
# arm : reboot (or nvram restore + reboot) in N s unless cancelled
( sleep 600; [ -f /tmp/keep-changes ] || reboot ) & echo $! >/tmp/dms.pid
# … UNcommitted changes (a reboot reverts to the committed state) …
# if OK : touch /tmp/keep-changes ; kill $(cat /tmp/dms.pid)   # disarm
```
Safeguards: (a) never touch `br0`/`lan_ifnames`/dropbear → **SSH :2222
survives everything**; (b) uncommitted changes → a reboot reverts them;
(c) full nvram backup; (d) physical presence as a last resort.
During the investigation, `br20`/`br30` were destroyed then restored without
ever losing SSH access.

---

## 8. Realistic path to restore NetA

Provision via the **Asus config layer** (which drives `mtlancfg`),
now that the MyPrivateNetwork↔`wl3.1` conflict is lifted:
1. Temporarily unblock the Asus UI (remove the `:8443` rule from `firewall-start`)
2. In the GUI: delete then recreate NetA → `cfg_server` allocates it a bridged slot
3. Verify the bridge to `br20`, then re-block the GUI
4. The webui then manages SSID/password on top

Unexplored alternative: drive `cfg_server` via CLI (uncertain).

---

## 8bis. RESOLUTION (2026-06-02) — NetA restored via the GUI

API attempts in the terminal (challenge-response login OK, captcha temporarily
disabled, POST `apply.cgi`):
- A **partial** apply (`apg4_enable`+`sdn_rl` only, without the full `apgX_rl`
  payload that the GUI sends) **corrupted the allocation**: `cfg_server` re-derived
  everything and kept only sdn2 → **NetB (sdn3) went down too**. A reboot
  did not repair it (persistent damage on the cfg_server side).
- **Recovery: re-save in the Guest Network Pro GUI.** The GUI sends the
  **complete** payload + preserves the existing allocations → `cfg_server`
  cleanly re-allocated **both NetB AND NetA**, multi-band:
  ```
  sdn4 (NetA/vid20) → wl3.3 (2.4G) + wl0.1 (5G) + wl2.1 (6G), bridged br20
  ```
  DHCP OK on br20 (10.0.20.x) and br30 (10.0.30.x).

**Lesson:** multi-band allocates just fine — but **only via the complete
GUI/cfg_server flow**. External nvram/API pokes (even authenticated as root)
do not trigger the allocation correctly and can corrupt the state. **Do not
drive `apply.cgi` with a partial payload.** To (re)provision a VLAN network:
**use the GUI** (then the webui manages SSID/password on top).

> Auth token: not forgeable offline (session secret internal to `httpd`,
> in memory, not written to file/nvram). The allocation is also not a CLI
> binary: it is compiled into `/sbin/rc`/`cfg_server`/`httpd`, reachable
> only via `apply.cgi`. Root grants write access, not control of this logic.

## 8ter. CORRECTION (2026-06-02) — `brctl` DOES bridge WiFi → the bypass IS possible

⚠️ The §5 conclusion ("only the driver can bridge a WiFi iface, `brctl` forbidden")
was **wrong** — based on a misinterpretation: `brctl addif br30 wl3.2`
returned "Operation not supported" only because `wl3.2` was **already**
a member of `br30`. Tested properly on a non-member iface:

```
brctl delif br0  wl3.1   → master=NONE   ✓
brctl addif br20 wl3.1   → master=br20   ✓✓✓   (and it HOLDS : stable at t+20s)
```

`/sbin/rc` itself uses `brctl addif br%d %s` for WiFi ifaces. So **the
webui can attach/detach a WiFi BSS from any bridge** (`brctl
delif`/`addif`), and it persists (unlike `wl bss down`, reverted in <1 s).

**Consequences:**
- **A real mtlancfg bypass is possible** for bridging: the webui controls
  the bridge membership of BSSes via `brctl`, on top of mtlancfg.
- **Strong disabling of the main network**: `brctl delif br0 wl3.1` →
  MyPrivateNetwork in no bridge → clients have no network at all (better than
  just hidden).
- Only caveat: mtlancfg re-bridges according to its config at boot/restart_wireless →
  a **"bridge-enforcer" watchdog** is needed that re-applies the desired mapping
  (like the ssid-suppressor). See [plan-bypass-mtlancfg.md](plans/plan-bypass-mtlancfg.md).

## 9. State left on the router

- NetB: OK (`wl3.2`→br30, DHCP 10.0.30.8) ✓
- **NetA: RESOLVED** (`wl3.3`+`wl0.1`+`wl2.1`→br20, DHCP 10.0.20.x) ✓ — via GUI re-save
- br20 / br30: OK ✓
- Backups: `/jffs/webui/backup/` (nvram, apg_ifnames_used.json, etc.)

### To restore (security posture, following the API tests)
- `captcha_enable=1` (was reset to 0 by the apply.cgi pokes — recommit needed)
- `:8443` block (reopened for the GUI recovery — re-block via firewall-start)
- MyPrivateNetwork (MAINFH) re-exposed: disable it **via the GUI** (do not redo
  nvram surgery on MAINFH)

## 10. SDN removal of MyPrivateNetwork (MAINFH) — IMPOSSIBLE (verified 2026-06-02)

Objective: make the main network completely disappear (not just hide it).
Real source identified: **`apm2`** in `cfg_server`/`common.json` — profile "AP
**Main**" 2 (`apm2_ssid=MyPrivateNetwork`, `apm2_dut_list=<*>1>` = 2.4 GHz/wl3,
`apm2_enable=1`). To be distinguished from `apm1` = `<hidden-ssid>…` hidden (`dut_list=<*>127>` =
all bands) = **MAINBH** (AiMesh backhaul), and from `apg3/apg4` = NetB/NetA.

Three levers tested (each behind dead-man, reverted):

| Lever | Action | Result |
|---|---|---|
| `sdn_rl` entry 2 | `MAINFH` enable `1→0` + `restart_wireless` | **no effect** — wl3.1 still beacons MyPrivateNetwork |
| nvram `apm2_enable=0` | + `restart_wireless` | **no effect** (nvram not overwritten, but BSS recreated) |
| `common.json` `apm2_enable=0` | edit 1 byte (valid JSON) + nvram + `restart_wireless` | **no effect**: `/tmp/wl3_hapd.conf` **regenerated** by mtlancfg **with** `bss=wl3.1 / ssid=MyPrivateNetwork` |

`/sbin/rc` does read `apm%d_enable` (string present), but **regenerates the
hostapd config of the main fronthaul no matter what**. The `hostapd_cli -i wl3.1 disable`
cuts the beacon but acts **per radio** (shared wl3 hostapd instance) → also kills
NetB (wl3.2) + NetA-2.4G (wl3.3). `wl bss down` is reverted in <1 s.

**Conclusion: the main fronthaul (MAINFH/`apm2`) is MANDATORY in the firmware.**
Consistent with the `is_main`/`main_fh` protection on the GUI side (`/www/SDN/sdn.js`). No
clean path (SDN/nvram/common.json) removes it; mtlancfg recreates it at every
`restart_wireless`/boot.

**Adopted floor (= v1.0.0, stable state):** MyPrivateNetwork **hidden**
(`ssid-suppressor` → `wl closed 1`, per-BSS, holds) **+ non-bridged**
(`bridge-enforcer` → `wl3.1=none`, per-BSS, holds). Invisible to scans + leads to
no network = practical equivalent of "non-existent" for any client. The only remnant
is a hidden beacon frame, not removable per-BSS without breaking NetB/NetA.
