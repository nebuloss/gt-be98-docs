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

# ---- ZERO-outage runtime edits (safe; one BSS only) -------------------------
guard_bss(){ is_protected_if "$1" && die "refusing protected interface: $1"; wl -i "$1" bssid >/dev/null 2>&1 || die "no such BSS: $1"; }
cmd_ssid(){ guard_bss "$1"; wl -i "$1" ssid "$2"; hostapd_cli -i "$1" update_beacon >/dev/null 2>&1 || true; echo "[V] $1 ssid -> $2 (no outage)"; }   # [V]
cmd_hide(){ guard_bss "$1"; wl -i "$1" closed 1; hostapd_cli -i "$1" update_beacon >/dev/null 2>&1 || true; echo "[V] $1 hidden"; }                     # [V]
cmd_show(){ guard_bss "$1"; wl -i "$1" closed 0; hostapd_cli -i "$1" update_beacon >/dev/null 2>&1 || true; echo "[V] $1 visible"; }                    # [V]
cmd_bss(){ guard_bss "$1"; case "$2" in up|down) wl -i "$1" bss "$2";; *) die "bss up|down";; esac; echo "[V] $1 bss $2"; }                             # [V]

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
get_cap_mac(){
	m=$(nvram get lan_hwaddr); [ -z "$m" ] && m=$(nvram get et0macaddr)
	[ -z "$m" ] && m=$(nvram get apg3_dut_list | sed 's/^<//; s/>.*//')
	echo "$m" | tr 'a-f' 'A-F'
}

# net-create <apg_idx> <vid> <ssid> <psk> [--apply] : create an SDN WiFi VLAN via
# the VERIFIED nvram path. apg<N>_* is cloned field-for-field from a working net
# (apg3/Pagoa), then sdn_rl/vlan_rl/subnet_rl get a new entry, then
# `rc sync_apgx_to_wlunit` (allocates a wlX.Y BSS slot + writes the /jffs alloc json)
# and `service restart_wireless;restart_sdn <sdnx>` bring it up. The kernel bridge is
# always br<VID>. Leaves nvram UNCOMMITTED (reboot reverts) — run `netctl commit` to
# persist after verifying. VERIFIED LIVE 2026-06-04: apg5/VID40 -> wl3.6 beaconed in
# br40, then clean-reverted.                                                       [V]
# Nuance: a NEW net is allocated a SINGLE band (2.4G/wl3) by sync_apgx_to_wlunit even
# with a multi-band security blob; existing nets keep their band allocation.        [V]
cmd_net_create(){
	apgx="$1"; vid="$2"; ssid="$3"; psk="$4"; apply="${5:-dry}"
	[ "$(nvram get apg${apgx}_enable)" = "1" ] && die "apg$apgx already in use"
	br="br${vid}"; is_protected_br "$br" && die "refusing protected bridge $br"
	echo "$(nvram get vlan_rl)" | tr '<' '\n' | awk -F'>' -v v="$vid" '$2==v{exit 3}'; [ $? -eq 3 ] && die "VID $vid already in vlan_rl"
	mac=$(get_cap_mac)
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
net-create plan (apg=$apgx sdn=$sdnx vlan_idx=$vlanx VID=$vid ssid=$ssid bridge=$br gw=${net}.1):
  nvram set apg${apgx}_{enable=1,ssid=$ssid,hide_ssid=0,disabled=0,macmode=disabled}
  nvram set apg${apgx}_bw_limit='<0>>' apg${apgx}_dut_list='<$mac>1>' apg${apgx}_mlo=''
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
	nvram set apg${apgx}_bw_limit='<0>>'; nvram set apg${apgx}_dut_list="<$mac>1>"; nvram set apg${apgx}_mlo=
	nvram set apg${apgx}_security="$sec"
	nvram set sdn_rl="$(nvram get sdn_rl)$sdnent"
	nvram set vlan_rl="$(nvram get vlan_rl)<$vlanx>$vid>0>"
	nvram set subnet_rl="$(nvram get subnet_rl)$subent"
	rc sync_apgx_to_wlunit
	service "restart_wireless;restart_sdn $sdnx"
	echo "[V] net-create applied (UNCOMMITTED): apg$apgx VID$vid ssid=$ssid -> br$vid"
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

# commit : persist the running nvram (after a verified net-create/net-delete).     [V]
cmd_commit(){ nvram commit; echo "nvram committed"; }

usage(){ cat <<EOF
netctl — GT-BE98 open network manager (reimplements cfg_server/mtlancfg net config)
  status                       radios + networks + bridges + clients   [safe]
  net-list                     list SDN networks                       [safe]
  ssid <bss> <name>            rename a BSS, no outage                  [safe]
  hide|show <bss>              hide/unhide a BSS, no outage             [safe]
  bss <bss> up|down            enable/disable a BSS                     [safe]
  bridge <bss> <br>            move a WiFi BSS to a VLAN bridge         [safe]
  net-create <apg> <vid> <ssid> <psk> [--apply]   create SDN WiFi VLAN [restart_wireless]
  net-delete <apg> [--apply]   tear down an SDN WiFi VLAN                [restart_wireless]
  commit                       persist running nvram (after verify)     [restart_wireless]
  deadman [secs] / keep        safety: self-recover reboot / disarm
  snapshot [file]              dump nvram for reversible tests
Protected (never touched): $PROTECTED_BRIDGES / $PROTECTED_IFACES
EOF
}

c="${1:-}"; shift 2>/dev/null || true
case "$c" in
	status) cmd_status;; net-list) cmd_net_list;;
	ssid) cmd_ssid "$@";; hide) cmd_hide "$@";; show) cmd_show "$@";;
	bss) cmd_bss "$@";; bridge) cmd_bridge "$@";;
	net-create) cmd_net_create "$@";; net-delete) cmd_net_delete "$@";; commit) cmd_commit;;
	deadman) cmd_deadman "$@";; keep) cmd_keep;; snapshot) cmd_snapshot "$@";;
	*) usage;;
esac
