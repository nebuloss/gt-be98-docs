# webui-go audit vs verified netctl behavior (P4)

> 2026-06-04. Cross-checked `gt-be98-webui-go/internal/api/{sdn,networks,radios,clients}.go`
> + `internal/sys/sys.go` against the live-verified primitives in
> [netctl-verified.md](netctl-verified.md) and [wl-interface.md](wl-interface.md).

## Verdict: aligned — no correctness divergences found

webui-go already implements the proven control path correctly:
- **Structural apply** (`sdn.go` `sdnSyncApply`/`applyOne`): `nvram set apg*` + `sdn_rl/
  vlan_rl/subnet_rl` splice → **`rc sync_apgx_to_wlunit`** → `nvram commit` →
  `service "restart_wireless;restart_sdn"`. Matches the verified recipe exactly.
- **Slot mapping**: `unitsForSSID()`/`ifacesBySSID()` *scan* `wlX.Y_ssid` after the sync
  instead of trusting a fixed slot — correctly handles the firmware reassigning BSS
  indices (the same wl3.6-style allocation netctl observed).
- **Security blob** (`securityString`): emits the `<127>auth>aes>pass>idx` all-band form.
  **Valid** — live DEV-SCEP (`<127>wpa2>aes>>5`) and Ramondia (`<127>wpa2wpa3>aes>>4`)
  use exactly this. (netctl uses the per-band `<3>…<13>…<16>…<96>` form, which is the
  other accepted encoding — Pagoa uses it. Both work; no fix needed.)
- **Control** uses `hostapd_cli` (`sys.HostapdCli`) and `wl` only for **reads**
  (`wlSSID` → `wl ssid` get). It never tries the verified-ineffective `wl ssid`-set or
  `wl bss down` on a managed BSS. ✓
- **Scoped apply** (`sdnScopedApply` + `fwHasScopedApply`) is correctly gated on the
  patched-firmware `restart_wireless_unit` capability — consistent with the finding that
  stock firmware has no per-radio restart.

## Enhancement opportunity (not a bug) — no-outage SSID-only edits

webui-go applies SSID edits through the full `restart_wireless` path (an all-radio
blip). The verified no-outage primitive (P0.4) would let an **SSID-only** change apply
with zero outage:

```
for u in ifacesBySSID()[oldSSID] {            // the live BSS units
    hostapd_cli -i u set ssid <new>           // NOT `wl ssid` (hostapd re-asserts that)
    hostapd_cli -i u update_beacon
}
nvram set apg<N>_ssid=<new>                    // persist; cfg_server keeps it on next sync
```

This is a fast-path *in addition to* the durable nvram path, applied only when the diff
is SSID-only. Left as a recommendation for the webui-go owner rather than a blind edit,
since it changes the product's apply semantics. The `disable`/`enable` and `set ssid`
verbs are already verified live (see netctl-verified.md P0.4).

## Suggested adoption (optional)
- Ship `owl` (open `wl` read path) alongside webui-go for an auditable, closed-`wl`-free
  status read (ssid/bssid/chanspec/bss/assoclist) — see [wl-interface.md](wl-interface.md).
