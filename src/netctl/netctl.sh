#!/bin/sh
# netctl — open-source network/WiFi/VLAN manager for the ASUS GT-BE98 (BCM6813).
#
# Reimplements the network-management role of the proprietary cfg_server/mtlancfg
# using the PROVEN primitives (see gt-be98-docs: behaviour.md, phase-b-webui-owns-wifi,
# plan-bypass-mtlancfg, wifi-apply-no-outage, cfg_server_re). Pure POSIX sh; uses the
# stock CLIs that exist on the router: nvram, wl, hostapd_cli, brctl, rc, service.
#
# SAFETY: never operate on the admin LAN path (br0 / eth* / dropbear). Runtime edits
# default to ZERO-outage. Structural apply (restart_wireless) is gated and pairs with
# a dead-man reboot so an unattended mistake self-recovers (uncommitted nvram reverts).
#
# Verified-live markers:  [V]=verified on the AP   [P]=per proven RE docs, recipe-coded
set -eu
# /sbin MUST be last: on this router /sbin/sh is a Broadcom memory tool (dw/sh/sb),
# not the shell. /bin first => sh=/bin/sh (busybox); rc/service (only in /sbin) still resolve.
export PATH=/bin:/usr/bin:/sbin:/usr/sbin

PROTECTED_BRIDGES="br0"                 # admin LAN — never touch
PROTECTED_IFACES="eth0 eth1 eth2 eth3 wl0.0 wl1.0 wl2.0 wl3.0"  # admin/primary BSS

die(){ echo "netctl: $*" >&2; exit 1; }
is_protected_if(){ for p in $PROTECTED_IFACES; do [ "$1" = "$p" ] && return 0; done; return 1; }
is_protected_br(){ for p in $PROTECTED_BRIDGES; do [ "$1" = "$p" ] && return 0; done; return 1; }
# NB busybox `command -v` here spuriously fails for /sbin/rc though `rc` runs fine,
# so scan PATH for an executable instead.                                          [V]
need(){ for d in $(echo "$PATH" | tr ':' ' '); do [ -x "$d/$1" ] && return 0; done; die "missing tool: $1"; }

# ---- safety: dead-man reboot ------------------------------------------------
# deadman <secs> : reboot in <secs> unless `netctl keep` is run first. Use before
# any restart_wireless test so a lost SSH self-recovers to the committed config.   [V-pattern]
cmd_deadman(){
	s="${1:-300}"; rm -f /tmp/netctl-keep
	( sleep "$s"; [ -f /tmp/netctl-keep ] || { logger -t netctl "dead-man reboot"; reboot; } ) >/dev/null 2>&1 &
	echo "dead-man armed: reboot in ${s}s unless 'netctl keep' (uncommitted nvram reverts)"
}
cmd_keep(){ : > /tmp/netctl-keep; echo "dead-man disarmed"; }

# ---- nvram snapshot/restore (for reversible tests) --------------------------
cmd_snapshot(){ f="${1:-/tmp/netctl-nvram.snap}"; nvram show 2>/dev/null > "$f"; echo "snapshot -> $f ($(wc -l < "$f") keys)"; }

# ---- read-only status -------------------------------------------------------
# status : radios, networks (SDN/apg), bridges, clients — replaces cfg_server's
# /tmp/*.json publishing.                                                          [V]
cmd_status(){
	echo "== radios =="
	for r in wl0 wl1 wl2 wl3; do
		printf "  %-4s nband=%s chanspec=%s ssid=%s closed=%s bss=%s\n" "$r" \
			"$(nvram get ${r}_nband)" "$(wl -i $r chanspec 2>/dev/null)" \
			"$(wl -i $r ssid 2>/dev/null | sed -n 's/.*"\(.*\)".*/\1/p')" \
			"$(wl -i $r closed 2>/dev/null)" "$(wl -i $r bss 2>/dev/null)"
	done
	echo "== networks (SDN) =="; cmd_net_list
	echo "== bridges =="; brctl show 2>/dev/null | sed 's/^/  /'
	echo "== clients (per non-primary BSS) =="
	for i in $(ls /var/run/hostapd/ 2>/dev/null | grep '\.'); do
		n=$(wl -i "$i" assoclist 2>/dev/null | grep -c assoclist || true)
		printf "  %-8s ssid=%-24s clients=%s\n" "$i" "$(wl -i $i ssid 2>/dev/null | sed -n 's/.*"\(.*\)".*/\1/p')" "$n"
	done
}

# clients [bss] : associated stations per BSS. `wl assoclist` gives the MACs (one
# "assoclist <MAC>" line each); hostapd_cli all_sta adds rssi/rate/connected_time.
# With no arg, every hostapd-managed BSS (the cfg_server client-report replacement). [V]
cmd_clients(){
	list="${1:-$(ls /var/run/hostapd/ 2>/dev/null | grep '\.')}"
	for i in $list; do
		ssid=$(wl -i "$i" ssid 2>/dev/null | sed -n 's/.*"\(.*\)".*/\1/p')
		macs=$(wl -i "$i" assoclist 2>/dev/null | sed -n 's/^assoclist //p')
		n=$(printf '%s' "$macs" | grep -c . || true)   # || true: grep -c exits 1 on 0
		printf "%-8s ssid=%-22s clients=%s\n" "$i" "${ssid:-?}" "$n"
		for m in $macs; do
			line=$(hostapd_cli -i "$i" sta "$m" 2>/dev/null || true)
			sig=$(printf '%s\n' "$line" | sed -n 's/^signal=//p' | head -1)
			rate=$(printf '%s\n' "$line" | sed -n 's/^tx_rate_info=//p' | head -1)
			ct=$(printf '%s\n' "$line" | sed -n 's/^connected_time=//p' | head -1)
			printf "    %s  signal=%sdBm tx_rate=[%s] conn=%ss\n" "$m" "${sig:-?}" "${rate:-?}" "${ct:-?}"
		done
	done
}

# channels : per-radio current chanspec + ACS exclusion list. Band is derived from the
# chanspec (6g* = 6 GHz, ch<=14 = 2.4 GHz, else 5 GHz). Radio map on GT-BE98:
# wl0/wl1 = 5 GHz (low/high segments), wl2 = 6 GHz, wl3 = 2.4 GHz.                 [V]
cmd_channels(){
	for r in wl0 wl1 wl2 wl3; do
		cs=$(wl -i "$r" chanspec 2>/dev/null)
		n=${cs%% *}; n=${n%%/*}
		case "$n" in
			6g*) band=6GHz;;
			*) if [ "$n" -le 14 ] 2>/dev/null; then band=2.4GHz; else band=5GHz; fi;;
		esac
		printf "  %-4s %-6s chanspec=%-18s acs_excl=%s\n" "$r" "$band" "${cs:-?}" "$(nvram get ${r}_acs_excl_chans)"
	done
}

# scan <radio> : passive site survey on ONE radio for channel planning. Triggers
# `wl <r> scan` (a brief off-channel dwell — can momentarily blip that radio's own
# clients; harmless on an idle radio e.g. wl2/6G) then parses `wl scanresults` into a
# neighbor table (BSSID/RSSI/channel/security/SSID) + a per-channel occupancy histogram.
# Read-only apart from the scan itself. Radios: wl3=2.4G wl0/wl1=5G wl2=6G.            [V]
cmd_scan(){
	r="${1:-}"; [ -n "$r" ] || die "usage: scan <radio>  (wl0|wl1|wl2|wl3); wl3=2.4G wl0/wl1=5G wl2=6G"
	ip link show "$r" >/dev/null 2>&1 || die "no such radio: $r"
	echo "scanning $r (brief off-channel dwell)..." >&2
	wl -i "$r" scan 2>/dev/null
	sleep 3
	out=$(wl -i "$r" scanresults 2>/dev/null | awk '
		function flush(){ if(bssid!=""){ printf "%-17s %5s %-12s %-9s %s\n", bssid, rssi, chan, sec, ssid } }
		/^SSID:/  { flush(); ssid=$0; sub(/^SSID: /,"",ssid); gsub(/"/,"",ssid); if(ssid=="")ssid="<hidden>";
		            bssid=""; rssi="?"; chan="?"; sec="Open" }
		/RSSI:/   { for(i=1;i<=NF;i++){ if($i=="RSSI:")rssi=$(i+1); if($i=="Channel:")chan=$(i+1) } }
		/^BSSID:/ { bssid=$2 }
		/RSN \(/  { s=$0; sub(/.*RSN \(/,"",s); sub(/\).*/,"",s); sec=s }
		/^WPA:/   { if(sec=="Open")sec="WPA" }
		END{ flush() }')
	n=$(printf '%s\n' "$out" | grep -c .)
	printf "%-17s %5s %-12s %-9s %s\n" "BSSID" "RSSI" "CHANNEL" "SECURITY" "SSID"
	printf '%s\n' "$out" | sort -k2 -rn          # strongest (least-negative RSSI) first
	echo "-- $n neighbor BSS on $r; channel occupancy --"
	printf '%s\n' "$out" | awk '{print $3}' | sort | uniq -c | sort -rn | awk '{printf "   ch %-12s %s\n", $2, $1}'
}

# net-list : parse sdn_rl + apg<N> into a network table.                          [V]
cmd_net_list(){
	echo "$(nvram get sdn_rl)" | tr '<' '\n' | while IFS='>' read -r idx type en vlanx subx apgx _; do
		[ -z "${idx:-}" ] && continue
		case "$type" in DEFAULT|MAINBH|MAINFH|"") continue;; esac
		vid=$(echo "$(nvram get vlan_rl)" | tr '<' '\n' | awk -F'>' -v v="$vlanx" '$1==v{print $2}')
		printf "  sdn=%s apg=%s vlan_idx=%s VID=%s enable=%s ssid=%s\n" \
			"$idx" "$apgx" "$vlanx" "${vid:-?}" "$en" "$(nvram get apg${apgx}_ssid)"
	done
}

# vlan-list : per VLAN bridge, classify members as BSS (beaconing) / fronthaul (silent
# wlX.<vid>) / eth (tagged uplink). Read-only view of the mtlancfg-built fabric. Reminder:
# bridge membership of a wl BSS is owned by mtlancfg (re-applied at restart_wireless/boot);
# `netctl bridge` moves are runtime-only. Durable membership = the SDN entry (net-create). [V]
cmd_vlan_list(){
	for br in $(brctl show 2>/dev/null | awk '$1 ~ /^br[0-9]/{print $1}'); do
		is_protected_br "$br" && { echo "$br (admin LAN — protected)"; continue; }
		vid=${br#br}; bss= fh= eth=
		for m in $(brctl show "$br" 2>/dev/null | awk -v b="$br" '$1==b{$1=$2=$3=""; print} $1!~/^br/ && NF==1{print}' | tr -s ' '); do
			case "$m" in
			eth*) eth="$eth $m";;
			*.${vid}) fh="$fh $m";;                      # wlX.<vid> = silent front-haul
			wl*) [ "$(wl -i "$m" isup 2>/dev/null)" = "1" ] && bss="$bss $m" || fh="$fh $m";;
			esac
		done
		printf "  %-6s VID=%-4s BSS:%s | fronthaul:%s | eth:%s\n" "$br" "$vid" "${bss:- -}" "${fh:- -}" "${eth:- -}"
	done
}

# ---- ZERO-outage runtime edits (safe; one BSS only) -------------------------
# existence via netdev/hostapd socket — both survive a `hostapd_cli disable`, unlike
# `wl bssid` (which errors on a disabled BSS, so it can't be used to gate `bss up`). [V]
guard_bss(){ is_protected_if "$1" && die "refusing protected interface: $1"; ip link show "$1" >/dev/null 2>&1 || [ -e "/var/run/hostapd/$1" ] || die "no such BSS: $1"; }
# SSID change MUST go through hostapd: on a hostapd-managed BSS `wl ssid` is re-asserted
# by hostapd and does NOT change the beacon (verified: get_config kept the old ssid).
# `hostapd_cli set ssid` + `update_beacon` DOES change the broadcast, no outage.    [V]
cmd_ssid(){ guard_bss "$1"; hostapd_cli -i "$1" set ssid "$2" >/dev/null && hostapd_cli -i "$1" update_beacon >/dev/null; echo "[V] $1 ssid -> $2 (no outage, via hostapd)"; }
cmd_hide(){ guard_bss "$1"; wl -i "$1" closed 1; hostapd_cli -i "$1" set ignore_broadcast_ssid 1 >/dev/null 2>&1; hostapd_cli -i "$1" update_beacon >/dev/null 2>&1 || true; echo "[V] $1 hidden"; }   # [V]
cmd_show(){ guard_bss "$1"; wl -i "$1" closed 0; hostapd_cli -i "$1" set ignore_broadcast_ssid 0 >/dev/null 2>&1; hostapd_cli -i "$1" update_beacon >/dev/null 2>&1 || true; echo "[V] $1 visible"; }  # [V]
# enable/disable via hostapd: `wl bss down` is reverted by the driver in <2s (verified);
# `hostapd_cli disable`/`enable` durably toggle that one BSS, no outage on siblings.  [V]
cmd_bss(){ guard_bss "$1"; case "$2" in up) hostapd_cli -i "$1" enable >/dev/null;; down) hostapd_cli -i "$1" disable >/dev/null;; *) die "bss up|down";; esac; echo "[V] $1 bss $2 (via hostapd)"; }

# bridge <bss> <target-br> : move a WiFi BSS between VLAN bridges (the proven
# brctl primitive — holds, unlike wl bss down).                                   [V]
cmd_bridge(){
	bss="$1"; tgt="$2"; guard_bss "$bss"; is_protected_br "$tgt" && die "refusing protected bridge: $tgt"
	cur=$(for b in $(brctl show 2>/dev/null | awk 'NF>=4{print $1} NF==1{print $1}'); do brctl show "$b" 2>/dev/null | grep -qw "$bss" && echo "$b"; done | head -1)
	[ -n "$cur" ] && brctl delif "$cur" "$bss" 2>/dev/null || true
	brctl addif "$tgt" "$bss"
	echo "[V] $bss : ${cur:-none} -> $tgt"
}

# ---- structural apply (restart_wireless) — GATED -----------------------------
# get_cap_mac : the router's own DUT MAC (uppercase) for apg<N>_dut_list.        [V]
# NB: on a standalone CAP, sync_apgx_to_wlunit/restart_wireless NORMALIZE an explicit
# CAP MAC to the wildcard "*" (all 3 live user nets converge to <*>...). net-create now
# uses <*> directly; this helper is kept for callers that want the literal MAC.       [V]
get_cap_mac(){
	m=$(nvram get lan_hwaddr); [ -z "$m" ] && m=$(nvram get et0macaddr)
	[ -z "$m" ] && m=$(nvram get apg3_dut_list | sed 's/^<//; s/>.*//')
	echo "$m" | tr 'a-f' 'A-F'
}

# bands_to_mask <spec> : comma list of band tokens -> apg<N>_dut_list band mask.
# The dut_list field is "<MAC|*>MASK>" where MASK is the OR of the per-radio band_idx
# bits that sync_apgx_to_wlunit allocates: 1=2.4G(wl3) 4=5G-low(wl0) 8=5G-high(wl1)
# 16=6G(wl2)  (bit 2 is reserved/unused — no radio). VERIFIED LIVE (t41/t41b 2026-06-05):
# mask 13 -> wl3.x+wl0.x+wl1.x all beacon; mask 29 -> + wl2.x (6G). Tokens:
#   2.4|2g  5|5g(both 5G)  5l 5h  6|6g  all(=2.4+5+6)                                  [V]
bands_to_mask(){
	m=0; OIFS=$IFS; IFS=,
	for b in $1; do case "$b" in
		2.4|2g|24)   m=$((m|1));;
		5|5g)        m=$((m|4|8));;
		5l|5g-low)   m=$((m|4));;
		5h|5g-high)  m=$((m|8));;
		6|6g)        m=$((m|16));;
		all)         m=$((m|1|4|8|16));;
		*) IFS=$OIFS; return 1;;
	esac; done
	IFS=$OIFS; [ "$m" -gt 0 ] || return 1; echo "$m"
}

# net-create <apg_idx> <vid> <ssid> <psk> [--apply] : create an SDN WiFi VLAN via
# the VERIFIED nvram path. apg<N>_* is cloned field-for-field from a working net
# (apg3/Pagoa), then sdn_rl/vlan_rl/subnet_rl get a new entry, then
# `rc sync_apgx_to_wlunit` (allocates a wlX.Y BSS slot + writes the /jffs alloc json)
# and `service restart_wireless;restart_sdn <sdnx>` bring it up. The kernel bridge is
# always br<VID>. Leaves nvram UNCOMMITTED (reboot reverts) — run `netctl commit` to
# persist after verifying. VERIFIED LIVE 2026-06-04: apg5/VID40 -> wl3.6 beaconed in
# br40, then clean-reverted.                                                       [V]
# MULTI-BAND (SOLVED 2026-06-05): the band count is driven by the apg<N>_dut_list mask,
# NOT the security blob. --bands selects it (default 2.4,5 = mask 13 = wl3+wl0+wl1, the
# same 3-band shape as the live user nets). t41/t41b verified mask 13 (3 bands beacon)
# and mask 29 (+6G/wl2).                                                            [V]
cmd_net_create(){
	apgx=""; vid=""; ssid=""; psk=""; apply="dry"; bands="2.4,5"
	while [ $# -gt 0 ]; do case "$1" in
		--apply)    apply="--apply";;
		--bands)    bands="$2"; shift;;
		--bands=*)  bands="${1#--bands=}";;
		*) if   [ -z "$apgx" ]; then apgx="$1"
		   elif [ -z "$vid" ];  then vid="$1"
		   elif [ -z "$ssid" ]; then ssid="$1"
		   elif [ -z "$psk" ];  then psk="$1"; fi;;
	esac; shift; done
	[ -n "$psk" ] || die "usage: net-create <apg> <vid> <ssid> <psk> [--bands 2.4,5,6|all] [--apply]"
	mask=$(bands_to_mask "$bands") || die "bad --bands '$bands' (tokens: 2.4 5 5l 5h 6 all)"
	[ "$(nvram get apg${apgx}_enable)" = "1" ] && die "apg$apgx already in use"
	br="br${vid}"; is_protected_br "$br" && die "refusing protected bridge $br"
	echo "$(nvram get vlan_rl)" | tr '<' '\n' | awk -F'>' -v v="$vid" '$2==v{exit 3}'; [ $? -eq 3 ] && die "VID $vid already in vlan_rl"
	# next sdn/vlan/subnet indices (max+1 over existing rls)
	sdnx=$(( $(nvram get sdn_rl | tr '<' '\n' | awk -F'>' 'NF>1{print $1}' | sort -n | tail -1) + 1 ))
	vlanx=$(( $(nvram get vlan_rl | tr '<' '\n' | awk -F'>' 'NF>1{print $1}' | sort -n | tail -1) + 1 ))
	subx=$vlanx
	sec="<3>pskpsk2>aes>${psk}>3<13>pskpsk2>aes>${psk}>3<16>sae>aes>${psk}>3<96>sae>aes>${psk}>3"
	# subnet: 192.168.<vid>.0/24 when vid<=254, else a /24 derived from sdnx
	o3="$vid"; [ "$vid" -gt 254 ] && o3=$(( 100 + sdnx ))
	net="192.168.${o3}"
	subent="<$subx>$br>${net}.1>255.255.255.0>0>${net}.2>${net}.254>86400>>,>>0>>0>0>>1000>2000>,,>0>1>"
	sdnent="<$sdnx>Customized>1>$vlanx>$subx>$apgx>0>0>0>0>0>0>0>0>0>0>0>0>0>WEB>0>0>0"
	cat <<EOF
net-create plan (apg=$apgx sdn=$sdnx vlan_idx=$vlanx VID=$vid ssid=$ssid bridge=$br gw=${net}.1 bands=$bands mask=$mask):
  nvram set apg${apgx}_{enable=1,ssid=$ssid,hide_ssid=0,disabled=0,macmode=disabled}
  nvram set apg${apgx}_bw_limit='<0>>' apg${apgx}_dut_list='<*>$mask>' apg${apgx}_mlo=''
  nvram set apg${apgx}_security='$sec'
  sdn_rl    += $sdnent
  vlan_rl   += <$vlanx>$vid>0>
  subnet_rl += $subent
  rc sync_apgx_to_wlunit ; service "restart_wireless;restart_sdn $sdnx"   # then: netctl commit
EOF
	[ "$apply" = "--apply" ] || { echo "(dry-run; pass --apply to execute — arm 'netctl deadman' first)"; return 0; }
	need rc
	nvram set apg${apgx}_enable=1; nvram set apg${apgx}_ssid="$ssid"; nvram set apg${apgx}_hide_ssid=0
	nvram set apg${apgx}_disabled=0; nvram set apg${apgx}_macmode=disabled
	nvram set apg${apgx}_bw_limit='<0>>'; nvram set apg${apgx}_dut_list="<*>$mask>"; nvram set apg${apgx}_mlo=
	nvram set apg${apgx}_security="$sec"
	nvram set sdn_rl="$(nvram get sdn_rl)$sdnent"
	nvram set vlan_rl="$(nvram get vlan_rl)<$vlanx>$vid>0>"
	nvram set subnet_rl="$(nvram get subnet_rl)$subent"
	rc sync_apgx_to_wlunit
	service "restart_wireless;restart_sdn $sdnx"
	echo "[V] net-create applied (UNCOMMITTED): apg$apgx VID$vid ssid=$ssid bands=$bands(mask $mask) -> br$vid"
	echo "verify the BSS beacons + SSH survives, then: netctl keep ; netctl commit"
}

# net-delete <apg_idx> [--apply] : tear down an SDN WiFi VLAN created by net-create.
# Removes the apg's sdn_rl/vlan_rl/subnet_rl entries, disables apg<N>, re-runs
# sync_apgx_to_wlunit (frees the slot in the /jffs alloc json) + restart. Refuses the
# built-in nets (DEFAULT/MAINBH/MAINFH) and any protected bridge. VERIFIED LIVE as the
# revert half of the net-create test (apg5/VID40 cleanly removed).                 [V]
cmd_net_delete(){
	apgx="$1"; apply="${2:-dry}"
	# locate the sdn_rl entry whose apg_idx==apgx
	row=$(nvram get sdn_rl | tr '<' '\n' | awk -F'>' -v a="$apgx" 'NF>1 && $6==a {print; exit}')
	[ -z "$row" ] && die "no sdn_rl entry references apg$apgx"
	sdnx=$(echo "$row" | cut -d'>' -f1); typ=$(echo "$row" | cut -d'>' -f2)
	vlanx=$(echo "$row" | cut -d'>' -f4); subx=$(echo "$row" | cut -d'>' -f5)
	case "$typ" in DEFAULT|MAINBH|MAINFH) die "refusing built-in net $typ (sdn$sdnx)";; esac
	vid=$(nvram get vlan_rl | tr '<' '\n' | awk -F'>' -v v="$vlanx" '$1==v{print $2}')
	[ -n "$vid" ] && { is_protected_br "br$vid" && die "refusing protected bridge br$vid"; }
	new_sdn=$(nvram get sdn_rl   | tr '<' '\n' | awk -F'>' -v s="$sdnx"  'NF>1 && $1!=s {printf "<%s",$0}')
	new_vln=$(nvram get vlan_rl  | tr '<' '\n' | awk -F'>' -v v="$vlanx" 'NF>1 && $1!=v {printf "<%s",$0}')
	new_sub=$(nvram get subnet_rl| tr '<' '\n' | awk -F'>' -v s="$subx"  'NF>1 && $1!=s {printf "<%s",$0}')
	echo "net-delete plan: apg=$apgx sdn=$sdnx vlan_idx=$vlanx VID=${vid:-?} bridge=br${vid:-?}"
	echo "  apg${apgx}_enable=0 (+clear ssid/security) ; drop sdn$sdnx/vlan$vlanx/subnet$subx"
	echo "  rc sync_apgx_to_wlunit ; service \"restart_wireless;restart_sdn $sdnx\" ; netctl commit"
	[ "$apply" = "--apply" ] || { echo "(dry-run; pass --apply to execute — arm 'netctl deadman' first)"; return 0; }
	need rc
	nvram set sdn_rl="$new_sdn"; nvram set vlan_rl="$new_vln"; nvram set subnet_rl="$new_sub"
	nvram set apg${apgx}_enable=0; nvram set apg${apgx}_ssid=; nvram set apg${apgx}_security=
	nvram set apg${apgx}_dut_list=; nvram set apg${apgx}_bw_limit=
	rc sync_apgx_to_wlunit
	service "restart_wireless;restart_sdn $sdnx"
	echo "[V] net-delete applied (UNCOMMITTED): apg$apgx / br${vid:-?} removed. Verify, then: netctl commit"
}

# apg_bss_list <apg_idx> : live beaconing BSS ifnames of an apg, from the /jffs alloc
# json (the wl_ifname entries under that apg's sdn_idx). Splitting on '{"sdn_idx"' puts
# each SDN entry (with all its band wl_ifnames) on one line.                        [V]
apg_bss_list(){
	sdnx=$(nvram get sdn_rl | tr '<' '\n' | awk -F'>' -v a="$1" 'NF>1 && $6==a{print $1; exit}')
	[ -z "$sdnx" ] && return 0
	f=/jffs/.sys/cfg_mnt/apg_ifnames_used.json; [ -r "$f" ] || return 0
	sed 's/{"sdn_idx"/\n{"sdn_idx"/g' "$f" | grep "\"sdn_idx\":\"$sdnx\"" \
		| grep -o '"wl_ifname":"[^"]*"' | sed 's/"wl_ifname":"//; s/"//'
}

# net-edit <apg> ssid <name> : rename every live BSS of apg<N> with ZERO outage
# (hostapd set ssid + update_beacon) and persist apg<N>_ssid in nvram. PSK/security
# edits have no reliable no-outage path while cfg_server owns /tmp/wlX_hapd.conf — use
# net-delete + net-create (restart_wireless) for those.                            [V]
cmd_net_edit(){
	apgx="$1"; field="$2"; val="$3"
	[ "$(nvram get apg${apgx}_enable)" = "1" ] || die "apg$apgx not enabled"
	case "$field" in
	ssid)
		[ -n "${val:-}" ] || die "net-edit $apgx ssid <name>"
		nvram set apg${apgx}_ssid="$val"
		n=0; for b in $(apg_bss_list "$apgx"); do
			is_protected_if "$b" && continue
			hostapd_cli -i "$b" set ssid "$val" >/dev/null 2>&1 && hostapd_cli -i "$b" update_beacon >/dev/null 2>&1 && n=$((n+1))
		done
		echo "[V] apg$apgx ssid -> $val on $n live BSS (no outage); nvram updated — 'netctl commit' to persist"
		;;
	psk)  die "no-outage PSK edit unsupported (cfg_server owns hostapd conf); use net-delete + net-create";;
	*)    die "net-edit <apg> ssid <name>";;
	esac
}

# commit : persist the running nvram (after a verified net-create/net-delete/net-edit). [V]
cmd_commit(){ nvram commit; echo "nvram committed"; }

usage(){ cat <<EOF
netctl — GT-BE98 open network manager (reimplements cfg_server/mtlancfg net config)
  status                       radios + networks + bridges + clients   [safe]
  net-list                     list SDN networks                       [safe]
  vlan-list                    VLAN bridges + BSS/fronthaul/eth members [safe]
  clients [bss]                associated stations (+rssi/rate)         [safe]
  channels                     per-radio chanspec + ACS exclusions      [safe]
  scan <radio>                 site survey on one radio (neighbors+chans)[brief blip]
  ssid <bss> <name>            rename a BSS, no outage                  [safe]
  hide|show <bss>              hide/unhide a BSS, no outage             [safe]
  bss <bss> up|down            enable/disable a BSS                     [safe]
  bridge <bss> <br>            move a WiFi BSS to a VLAN bridge         [safe]
  net-create <apg> <vid> <ssid> <psk> [--bands 2.4,5,6|all] [--apply]  create SDN WiFi VLAN
                               (--bands default 2.4,5 = 3 bands; tokens 2.4 5 5l 5h 6 all) [restart_wireless]
  net-delete <apg> [--apply]   tear down an SDN WiFi VLAN                [restart_wireless]
  net-edit <apg> ssid <name>   rename all of an apg's BSS, no outage    [safe]
  commit                       persist running nvram (after verify)     [—]
  deadman [secs] / keep        safety: self-recover reboot / disarm
  snapshot [file]              dump nvram for reversible tests
Protected (never touched): $PROTECTED_BRIDGES / $PROTECTED_IFACES
EOF
}

c="${1:-}"; shift 2>/dev/null || true
case "$c" in
	status) cmd_status;; net-list) cmd_net_list;; vlan-list) cmd_vlan_list;; clients) cmd_clients "$@";; channels) cmd_channels;;
	scan) cmd_scan "$@";;
	ssid) cmd_ssid "$@";; hide) cmd_hide "$@";; show) cmd_show "$@";;
	bss) cmd_bss "$@";; bridge) cmd_bridge "$@";;
	net-create) cmd_net_create "$@";; net-delete) cmd_net_delete "$@";; net-edit) cmd_net_edit "$@";; commit) cmd_commit;;
	deadman) cmd_deadman "$@";; keep) cmd_keep;; snapshot) cmd_snapshot "$@";;
	*) usage;;
esac
