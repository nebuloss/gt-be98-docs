# gt-be98-docs

Investigation, reverse-engineering notes, and design plans for the **Asus GT-BE98**
router (Broadcom BCM6813, ASUSWRT/Merlin) — the verified behaviour behind a custom
web UI and custom firmware that replace/constrain the stock Asus stack.

This is the documentation/forensics repo. The code lives elsewhere:
- **Web UI** (Go backend on the router): `gt-be98-webui-go`
- **Custom firmware** (gnuton ASUSWRT-Merlin build): `gt-be98-firmware`

> **Redaction:** this repo is public, so device identifiers are anonymized —
> router MACs/BSSIDs appear as `<redacted-mac>`, the hidden management SSID as
> `<hidden-ssid>`, and the two real user-network names as `NetA` / `NetB`. The
> behaviour described is unchanged. Some `plans/*.md` are historical (they reference
> the old shell-backend paths `src/www/`, `api.sh`, `networks.sh`).

## Start here

- [comportement.md](comportement.md) — **verified SDN/apg model** (how Asus SDN VLAN
  WiFi actually works: `sdn_rl`/`vlan_rl`/`subnet_rl`/`apg*`, dut_list band masks).
- [sdn_investigation.md](sdn_investigation.md) — why VLAN bridging can't be owned from
  outside the firmware, and the forensic trail that led to the firmware fixes.
- [main-wifi-admin-lan.md](main-wifi-admin-lan.md) — the main WiFi is bridged to the
  untagged admin LAN and the stock GUI can't disable it: verified topology, live
  experiments (E1–E8), and remediation options.
- [wifi-apply-no-outage.md](wifi-apply-no-outage.md) — per-radio hostapd model: how to
  create/edit WiFi without the global `restart_wireless` outage.

## Reference

- [architecture.md](architecture.md) — system overview.
- [hardware.md](hardware.md) — radio/band map, BSS interfaces, hardware facts.
- [topologie.md](topologie.md) — network topology.
- [nvram_schema.md](nvram_schema.md) — nvram keys used by the SDN/WiFi model.
- [hostapd_schema.md](hostapd_schema.md) — generated `wlX_hapd.conf` structure.
- [tools.md](tools.md) — on-device tooling notes.

## Plans

- [plans/plan-firmware-full-control.md](plans/plan-firmware-full-control.md) —
  source-grounded plan to make the webui the sole WiFi control plane via minimal,
  nvram-gated firmware patches (0028 primary-bridge control, 0029 per-radio apply,
  0030 cfg_server neutralization), with cross-compile + live-probe validation.
- [plans/plan-remove-stock-services.md](plans/plan-remove-stock-services.md) — strip the
  stock Asus daemons/UI; webui = sole control plane.
- [plans/plan-bypass-mtlancfg.md](plans/plan-bypass-mtlancfg.md),
  [plans/phase-b-webui-owns-wifi.md](plans/phase-b-webui-owns-wifi.md),
  [plans/phase-b2-sdn-nvram-spec.md](plans/phase-b2-sdn-nvram-spec.md),
  [plans/next-phase-firmware-re.md](plans/next-phase-firmware-re.md) — WiFi-ownership phases.

> WebUI-app-specific plans (save-network flow, RADIUS, client list, WPA-enterprise)
> live in the **gt-be98-webui-go** repo (`docs/`), not here. This repo is consumed by
> that repo as a submodule at `docs/device/`.
