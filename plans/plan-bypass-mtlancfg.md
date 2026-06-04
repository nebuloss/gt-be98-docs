# Plan — bypass mtlancfg (provisioning WiFi VLANs without the Asus GUI)

> Goal: have the webui provision/manage WiFi VLAN networks **without depending on the
> Asus GUI or cfg_server**. Current state: the GUI/cfg_server/mtlancfg are
> required *once* per structural change (VLAN creation/binding, WPA
> password). Ref.: [sdn_investigation.md](../sdn_investigation.md).

## The single blocker

Everything needed for a WiFi VLAN, the webui already knows how to do **except one thing**:

| Element of a VLAN | Doable by the webui? |
|---|---|
| Create the bridge `br<vlan>` (`ip link add … type bridge`) | ✅ yes |
| Create/tag the ethernet uplink `eth*.vid` + add it to the bridge | ✅ yes (ethernet interfaces) |
| Beacon the SSID (hostapd / `wl ssid`) | ✅ yes |
| **Attach the WiFi BSS (`wlX.Y`) to the bridge** | ❌ **NO** — the `wl` driver refuses `brctl`/`ip link` ("Operation not supported") |

So "bypassing mtlancfg" boils down to **a single problem**: finding how to
attach a WiFi interface to a bridge without going through mtlancfg. If we crack that,
the webui becomes autonomous (it creates bridges + tags + WiFi bridge + beacon itself).

---

## Track B — The real bypass: the primitive is `brctl` ✅ FOUND (2026-06-02)

> **B1 SOLVED.** The WiFi bridging primitive is simply **`brctl
> delif`/`addif`** — tested: `brctl delif br0 wl3.1` then `brctl addif br20 wl3.1`
> → `wl3.1` moves into `br20`, **and it holds** (stable at t+20s, unlike
> `wl bss down`). The initial failure ("Operation not supported") was due to the
> fact that the iface was *already* a member of the target bridge. `/sbin/rc` actually uses
> `brctl addif`. → The webui can own WiFi bridging. What remains is to **maintain** it
> (mtlancfg re-bridges at boot/restart_wireless) via a "bridge-enforcer" watchdog.

Idea: mtlancfg *does* attach `wl3.2` to `br30` — so a primitive exists.
We need to **observe exactly what it does** and **replay** it directly.

### B1 — Discover the primitive (how the driver bridges a BSS)
Without presuming the means, test in order:
1. **per-interface nvram**: `nvram set wl3.2_bridge=br30` (or `_vifname`/`_lanaccess`)
   then a light re-init of the BSS (`wlconf wl3.2 up` / `wl -i wl3.2 bss up`) — does the driver
   re-read it and bridge it? (fast, reversible)
2. **lanX_ifnames + driver re-init without mtlancfg**: find a command that makes
   the driver re-read `lanX_ifnames` outside `restart_wireless` (which calls mtlancfg back).
3. **Trace mtlancfg**: if `strace`/`ltrace` available (otherwise push them via Entware/
   a static binary), trace a `restart_wireless` and isolate the exact call that
   puts `wl3.2` into `br30` (`SIOCBRADDIF` ioctl? `wl`/`et`/`dhd` call? sysfs
   write?). Failing strace: diff `/sys/class/net/*/brport`, dmesg, and analyze
   `strings /sbin/rc | grep -iE "addif|bridge|brctl|SIOCBR"`.
4. **Kernel hook**: check whether the addition goes through a module (`dhd`/`wl`) exposing
   an undocumented `wl` subcmd (`wl -i wl3.2 ?` exhaustively, grep "bridge|br_").

### B2 — Replay the primitive
Once the primitive is isolated → encapsulate it in a webui function `wl_bridge_add
<iface> <bridge>`.

### B3 — 100% webui provisioning (if B1 succeeds)
The webui, per VLAN network:
1. `ip link add br<vlan> type bridge` (if absent) + `ip link set br<vlan> up`
2. `ip link add link ethX name ethX.<vlan> type vlan id <vlan>` + add it to br<vlan>
   (+ switch tag `ethswctl`/`vlanctl` if needed for the physical trunk)
3. create/enable the BSS (`wlX.Y`, nvram `bss_enabled`, ssid, security) + **wl_bridge_add wlX.Y br<vlan>**
4. hostapd/`wl` for the beacon + WPA
5. neutralize mtlancfg on these VLANs so it doesn't re-overwrite (cf. B1.2)

**Probable verdict**: uncertain. The driver *may* only gatekeep via its init.
If no external primitive exists → Track A. But B is the only real bypass;
**to be spiked first (bounded, reversible).**

---

## Track A — Proven-feasible fallback: drive cfg_server via apply.cgi (without the GUI)

Does not bypass mtlancfg, but **removes the dependency on the GUI**: the webui replays
the full `apply.cgi` request the GUI sends → cfg_server allocates+bridges.
Proven today: `login_v2.cgi` login (sha256 challenge) OK, `apply.cgi` accepts,
the **complete** payload triggers the allocation (the *partial* payload corrupted it).

- **A1** Capture/derive the **complete** payload of an SDN add/edit (all the
  `apgX_rl` fields via `parse_apg_rl_to_apgX_rl` + `sdn_rl` + `vlan_rl` + cp/radius).
  Source: devtools on the GUI once, or reverse-engineer `sdn.js` (≈724 KB).
- **A2** Auth in the webui backend: `id`→`get_Nonce.cgi`→`nonce`, `cnonce`,
  `login_authorization=sha256(admin:nonce:pass:cnonce)`→`login_v2.cgi`→`asus_token`.
  CAPTCHA: `captcha_enable=0` around the call (root), restore afterwards.
- **A3** webui "provision SDN" action: maps networks.conf → apg/sdn_rl fields,
  builds the complete payload, POST `apply.cgi` (`action_mode=apply` +
  `rc_service=restart_wireless;restart_sdn <idx>`).
- **A4** Encode the `apg<N>_security` blob (per band: akm/crypto/psk, 6 GHz=sae) —
  decoded from existing profiles.
- **A5** Idempotency + verification (read `apg_ifnames_used.json` + bridging afterwards).

**Risk**: fragile, specific to the firmware version; a partial payload
corrupts (seen today — NetB went down). Mitigations §Safety.

---

## Safety / method (both tracks)

- **Dead-man switch**: `( sleep 600; [ -f /tmp/keep-changes ] || reboot ) &` before
  any risky test; disarm if OK. (Variant: restore nvram + reboot.)
- **Never touch `br0`/`lan_ifnames`/dropbear** → SSH `:2222` remains the fallback access.
- **Backups**: `nvram show` + `/jffs/.sys/cfg_mnt/*.json` before each attempt.
- **Test on a disposable VLAN** (e.g. VLAN 40), not on NetA/NetB.
- **Uncommitted changes** when possible (a reboot undoes them).
- Lessons: busybox has no `printf '%q'` (→ escaped single quotes); a partial
  `apply.cgi` apply corrupts the allocation (always full payload).

---

## Recommendation

1. **Spike Track B** (bounded, ~1 session): isolate the WiFi bridging primitive.
   If found → real bypass, autonomous webui.
2. **Otherwise, Track A**: `apply.cgi` bridge → independence from the GUI (but
   cfg_server stays under the hood).
3. In both cases, the webui remains the day-to-day layer; mtlancfg/cfg_server
   are only invoked at structural provisioning (Track A) or no longer at all (Track B succeeded).
