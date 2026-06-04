# hostapd — GT-BE98 configuration schema

> 📌 The hostapd config **actually generated** by `cfg_server` on the router (keys,
> `wpa_key_mgmt`, MFP, Wi-Fi 7…) is captured live in
> [behaviour.md](behaviour.md) **§12.6**. The "hostapd-direct" approach below
> is historical (superseded by SDN/apg + firmware patch 0025).

## Key discovery

The Asus firmware uses hostapd under the hood, but its
nvram → wlconf → hostapd pipeline is buggy/limited for multi-VLAN setups.

The chosen approach: **write the hostapd configs directly** and
restart hostapd, completely bypassing Asus.

Persistent source of truth: `/jffs/scripts/services-start`
Active configs (tmpfs, lost on reboot): `/tmp/wlX_hapd.conf`

## Files per radio

```
/tmp/wl0_hapd.conf   5 GHz-1  (channel 36,  hw_mode=a)
/tmp/wl1_hapd.conf   5 GHz-2  (channel 108, hw_mode=a)
/tmp/wl2_hapd.conf   6 GHz    (channel 1,   hw_mode=a, WPA3 mandatory)
/tmp/wl3_hapd.conf   2.4 GHz  (channel 1,   hw_mode=g)
```

## Structure of a file

```
[main interface section]         ← physical radio (hidden SSID = Asus network)
[bss=wlX.N section]              ← virtual BSS #1 (VLAN N)
[bss=wlX.M section]              ← virtual BSS #2
...
```

## Main interface section (radio)

```ini
driver=nl80211
ctrl_interface_group=0
interface=wl0
hw_mode=a                        # a=5G/6G  g=2.4G
channel=36                       # 0=auto
country_code=E0
ieee80211d=1
ieee80211h=1
beacon_int=100
bridge=br0
ctrl_interface=/var/run/hostapd
ssid=<HASHED_SSID>               # hidden Asus SSID (ignore_broadcast_ssid=1)
ignore_broadcast_ssid=1
auth_algs=1
wpa=2
wpa_key_mgmt=WPA-PSK SAE SAE-EXT-KEY
wpa_pairwise=CCMP GCMP-256
wpa_passphrase=<HASHED_PASSWORD>
ieee80211be=1                    # Wi-Fi 7 enabled
ft_rrb_lo_sock=1
```

## Virtual BSS section (custom network)

```ini
bss=wl0.1                        # virtual interface
bridge=br20                      # target VLAN bridge
ctrl_interface=/var/run/hostapd
bssid=<redacted-mac>          # fixed MAC (must match the interface)
ssid=NetA
ignore_broadcast_ssid=0          # SSID visible
auth_algs=1
ap_isolate=0
wpa=2
ieee80211be=0                    # Wi-Fi 7 disabled on virtual BSS (current)
```

### Security by band

**2.4 GHz and 5 GHz (wl0, wl1, wl3) — WPA2 or WPA2+WPA3:**
```ini
wpa_key_mgmt=WPA-PSK              # WPA2 only
# or
wpa_key_mgmt=WPA-PSK SAE          # WPA2+WPA3
wpa_pairwise=CCMP
wpa_passphrase=mypassword
ieee80211w=0                      # WPA2 only
# or
ieee80211w=1                      # WPA2+WPA3
```

**6 GHz (wl2) — WPA3 MANDATORY:**
```ini
wpa_key_mgmt=SAE
wpa_pairwise=CCMP GCMP-256
sae_password=mypassword           # not wpa_passphrase !
sae_require_mfp=1
sae_pwe=1
ieee80211w=2                      # MFP required
```

## Fixed BSSIDs per slot

These MACs are hardcoded in the firmware (pre-created virtual interfaces):

| Slot | wl0 | wl1 | wl2 | wl3 |
|---|---|---|---|---|
| .1 | <redacted-mac> | <redacted-mac> | <redacted-mac> | <redacted-mac> |
| .2 | ? | ? | ? | <redacted-mac> |
| .3 | ? | ? | ? | ? |

To be completed via: `ip link show | grep wl` after activating the slots.

## Apply commands

```sh
# Kill existing hostapd
killall hostapd 2>/dev/null
sleep 2

# Relaunch with all the radio files
hostapd /tmp/wl0_hapd.conf /tmp/wl1_hapd.conf \
        /tmp/wl2_hapd.conf /tmp/wl3_hapd.conf -B

# Verify
sleep 2 && hostapd_cli -i wl0.1 status
```

Advantage vs `service restart_wireless`:
- Restarts **only hostapd** (not the whole network stack)
- Faster (~2s vs ~5s)
- No loss of connectivity on non-Wi-Fi interfaces

## Persistence

The `/tmp/wlX_hapd.conf` configs are on tmpfs → lost on reboot.

Persistence is handled via `/jffs/scripts/services-start`, which:
1. Sets the nvram values (so the Asus UI shows something)
2. Waits until hostapd is started by Asus (`while [ $i -lt 60 ]`)
3. **Overwrites** the `/tmp/wlX_hapd.conf` configs with the correct values
4. Restarts hostapd with the correct configs

## UI → backend architecture

```
UI (browser)
  │  POST /cgi-bin/api.sh?action=save_network
  ▼
api.sh (shell CGI)
  ├─ 1. Validates the parameters
  ├─ 2. Regenerates the hapd sections for the modified network
  ├─ 3. Rewrites /jffs/scripts/services-start (persistence)
  ├─ 4. Writes /tmp/wlX_hapd.conf (immediate apply)
  └─ 5. killall hostapd && hostapd ... -B

UI receives { "ok": true } and refreshes the state
```
