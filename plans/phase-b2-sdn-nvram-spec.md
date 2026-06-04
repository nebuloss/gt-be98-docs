---
name: phase-b2-sdn-nvram-spec
description: "Authoritative nvram SDN profile format (sdn_rl/vlan_rl/subnet_rl/apg) + dut_list band map, reverse-engineered from web.c — the spec net_apply_all replicates"
metadata: 
  node_type: memory
  type: project
  originSessionId: d2d0b286-a24f-4c7c-b7d0-99c65d116ccf
---

**B2 authoritative spec** (from `../gt-be98-firmware` web.c `create_sdn_profile`@43329,
`create_sdn_guest_profile`@43740, `web_get_availabel_sdn_profile`@43112,
`update_alexa_ifttt_guestnetwork`@23248; verified against live nvram 2026-06-03). This is
what `net_apply_all` in `cgi-bin/lib/networks.sh` replicates. See [[phase-b-webui-owns-wifi]].

**Index allocation** (port of web_get_availabel_sdn_profile): parse `sdn_rl` entries →
mark used sdn_idx / apg_idx (apm_idx if name is MAINFH|MAINBH) / subnet_idx; parse `vlan_rl`
→ used vlan_idx. Free index = lowest ≥1 not used (per array). Live free set: sdn_idx 5,
apg_idx 5, subnet_idx 3, vlan_idx 3. VID + subnet are user-chosen by the webui (GUI auto-picks
vid=51+, subnet 192.168.<51+mtlan_sz-1>.1; **we use VID-aligned 192.168.<VID>.0/24** to match
existing NetB(VID30→.30)/NetA(VID20→.20)).

**sdn_rl** (22 fields, SDN_LIST_BASIC_PARAM): append
`<sdn_idx>Customized>1>vlan_idx>subnet_idx>apg_idx>0>0>0>0>0>0>0>0>0>0>0>0>0>WEB>0>0`
(fields: idx,name,enable,vlan_idx,subnet_idx,apg_idx,vpnc,vpns,dnsf,urlf,nwf,cp,gre,fw,killsw,ahs,wan,ppprelay,wan6,**createby=WEB**,mtwan,mswan).

**vlan_rl**: append `<vlan_idx>VID>0`  (idx>vid>port_isolation).

**subnet_rl**: append
`<subnet_idx>br<VID>>192.168.<VID>.1>255.255.255.0>1>192.168.<VID>.2>192.168.<VID>.254>86400>>,>>0>>`.
(bridge-name field is `br<VID>`; live NetB shows stale "br54" but actual Linux bridge is
br<VID> — closed code derives br<VID> from vid, so the field value isn't load-bearing.)

**apg<apg_idx>_ fields** (APXx_NVRAM_LIST): enable=1, ssid=<name>, hide_ssid=0|1,
ap_isolate=0|1, bw_limit=`<0>>`, macmode=0, maclist="", timesched=0,
**dut_list=`<*>BANDMASK>`**, security=`<127>AUTH>aes>PSK>SDN_IDX` (`<127>`=all-bands wildcard;
band 0→127). Empty: sched, iot_max_cmpt, mlo, expiretime, 11be, disabled.

**dut_list BANDMASK** (WIFI_BAND_* bits, shared.h:484; verified: NetA=21=1+4+16 → wl3+wl0+wl2,
NOT wl1): **wl3(2.4G)=1, wl0(5G-1/5GL)=4, wl1(5G-2/5GH)=8, wl2(6G)=16**. Sum the bits for the
selected radios. (NetB=1=wl3-only ✓.)

**security**: simple form `<127>AUTH>aes>PSK>SDN_IDX`. AUTH tokens seen live: psk2, pskpsk2, sae.
⚠️ 6GHz (wl2) requires SAE — `<127>` is one token for all bands, so a psk2-only token breaks wl2.
**UNVALIDATED:** exact token for WPA2/WPA3-transition incl. 6G, and the enterprise/RADIUS string
format (DEV-SCEP NET_3 is the enterprise test case). Validate by creating a test net, then
inspect derived `wlX.Y_auth_mode`/`wlX.Y_wpa_psk` + try associating before trusting.

**Apply (run ONCE after all create/edit/delete):**
`nvram set w_Setting 1` (if 0) → `rc sync_apgx_to_wlunit` (derives wlX.Y_* from apg; rc.c:540) →
`nvram commit` → `service "restart_wireless;restart_sdn"`. ⚠️ drops WiFi ~5s.

**Delete** = splice: rebuild sdn_rl/vlan_rl/subnet_rl dropping the entry's idx; clear apg<apg_idx>_*
to defaults; then Apply. ⚠ Apply MUST include `rc sync_apgx_to_wlunit` — a bare `restart_wireless`
does NOT re-derive wlX.Y_ssid, leaving the deleted SSID stale in derived nvram. (The code path does
this; only manual splice-without-sync leaves staleness.)

**LIVE-VALIDATED 2026-06-03** (created throwaway B2TEST VID60 wl3, then deleted; router restored
exactly): index alloc, apg/sdn_rl/vlan_rl/subnet_rl composition, dut_list bandmask, adoption
(NetB→apg3/NetA→apg4, no dup), and **delete/splice** all correct. apg_idx reuse is correct:
free apg=1 (apg1 "test" was an orphaned disabled leftover; MAINBH/MAINFH live in **apm1/apm2**, NOT
apg). create→SSID broadcasts on the right radios with the VLAN bridge (br<VID>) — **L2 works**.

**L3 GAP + the existing nets are L2-only (KEY):** `restart_wireless;restart_sdn` (the exact GUI
sequence) creates the bridge L2 but does NOT hot-assign a *new* SDN bridge's IP from CLI — that
`ifconfig br<VID> 192.168.<VID>.1` is done by the closed boot/lan path only. BUT this is moot here:
the user's NetB/NetA have **`dhcp_enable=0`** (subnet_rl field 5), **no router IP on br20/br30,
no dnsmasq-3/4 leases, NAT pointing at phantom br54/br55** → they are **pure L2 VLAN trunks** (clients
addressed upstream, router only tags VLANs). So a created net should match: **write subnet_rl
dhcp_enable=`0`** (my create template copied the GUI's `1`; change to `0`) → no L3 wanted, no ifconfig
step, no gap. If router-as-gateway+DHCP per VLAN is ever wanted, the recipe is: restart_wireless →
wait for br<VID> → `ifconfig br<VID> <ip> netmask <m> up` → `restart_sdn <idx>` (then dnsmasq-<idx>
binds + serves; validated live).

**DECISION (user, 2026-06-03): L2-only.** `net_sdn_create` writes subnet_rl dhcp_enable=`0`. B2 DONE
& validated E2E through the real code paths (`net_apply_one` save; `net_sdn_remove`+`net_delete`+
`net_sdn_sync_apply` delete): created SSID broadcasts on the chosen radios, br<VID> L2 bridge up with
no IP/no dnsmasq (matches NetB/NetA), delete splices cleanly + sync clears derived SSID, router
restored exactly. Code shipped in `cgi-bin/lib/networks.sh` + `api.sh` (deployed). Remaining: B3 wire
the frontend editor to the now-real apply; B4 delete dead code (hapd_gen.sh, net_write_services_start).
⚠ enterprise/RADIUS security string still unvalidated (DEV-SCEP NET_3).

**Adoption problem:** networks.conf NET_1(NetA)/NET_2(NetB) exist as apg4/apg3 but were made
via Asus GUI and have NO stored indices — naive "no index = create" would DUPLICATE them. net_apply_all
must adopt-by-SSID (match existing apg*_ssid → store its indices) before creating. Webui stores the
allocated indices back into networks.conf as NET_<id>_{SDN_IDX,APG_IDX,VLAN_IDX,SUBNET_IDX}.
