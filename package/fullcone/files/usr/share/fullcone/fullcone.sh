#!/bin/sh
# UDP (and, with option tcp, TCP) full cone NAT for fw4 via xt_FULLCONENAT (iptables-nft, table ip nat).
# fw4 sources this file as a firewall include with no arguments (= apply) after every
# start/reload; it must never call fw4 itself (fw4 holds its lock while running includes).
# Usage: fullcone.sh [apply|status|stop]; FULLCONE_FORCE=1 applies while disabled in uci.

IPT="iptables-nft -w -t nat"

fc_get() {
	uci -q get "fullcone.main.$1"
}

# Derived from uci, not runtime state: at boot fw4 runs before network is up.
fc_lan() {
	local v
	v=$(fc_get lan_subnet)
	[ -n "$v" ] && { echo "$v"; return; }
	v=$(uci -q get network.lan.ipaddr | cut -d' ' -f1)
	case "$v" in
	*/*) v=$(/bin/ipcalc.sh "$v") ;;
	?*) v=$(/bin/ipcalc.sh "$v" "$(uci -q get network.lan.netmask)") ;;
	esac
	echo "$v" | awk -F= '$1 == "NETWORK" { n = $2 } $1 == "PREFIX" { p = $2 } END { if (n && p) print n "/" p }'
}

fc_wan() {
	local v
	v=$(fc_get wan_device)
	[ -n "$v" ] && { echo "$v"; return; }
	v=$(uci -q get network.wan.proto)
	case "$v" in
	pppoe|pppoa|pptp|l2tp) echo "$v-wan" ;;
	*) uci -q get network.wan.device ;;
	esac
}

# One list drives both the FULLCONENAT rules and the fw4 bypass set, so they cannot disagree.
fc_protos() {
	if [ "$(fc_get tcp)" = 1 ]; then echo "udp tcp"; else echo udp; fi
}

fc_sets_flush() {
	nft flush set inet fw4 fullcone_proto 2>/dev/null
	nft flush set inet fw4 fullcone_lan 2>/dev/null
	nft flush set inet fw4 fullcone_wan 2>/dev/null
}

fc_rmmod() {
	grep -q '^xt_FULLCONENAT ' /proc/modules || return 0
	# nft_compat drops the target reference from a work queue after the rule flush.
	rmmod xt_FULLCONENAT 2>/dev/null || { sleep 1; rmmod xt_FULLCONENAT 2>/dev/null; }
}

fc_rules() {
	local lan=$1 wan=$2 protos=$3 proto p
	[ -n "$lan" ] && [ -n "$wan" ] && modprobe xt_FULLCONENAT || return 1
	for proto in $protos; do
		for p in $(fc_get exclude_port); do
			$IPT -A FULLCONE_PRE -i "$wan" -p "$proto" --dport "$p" -j RETURN || return 1
		done
		$IPT -A FULLCONE_PRE -i "$wan" -p "$proto" -j FULLCONENAT &&
		$IPT -A FULLCONE_POST -o "$wan" -s "$lan" -p "$proto" -j FULLCONENAT || return 1
	done
}

fc_apply() {
	local lan wan protos c
	# Sets first: an empty set makes fw4 masquerade everything again.
	fc_sets_flush
	for c in PRE POST; do
		$IPT -N FULLCONE_$c 2>/dev/null
		$IPT -F FULLCONE_$c
	done
	$IPT -C PREROUTING -j FULLCONE_PRE 2>/dev/null || $IPT -A PREROUTING -j FULLCONE_PRE
	$IPT -C POSTROUTING -j FULLCONE_POST 2>/dev/null || $IPT -A POSTROUTING -j FULLCONE_POST

	if [ "$(fc_get enabled)" != 1 ] && [ "$FULLCONE_FORCE" != 1 ]; then
		fc_rmmod
		return 0
	fi

	lan=$(fc_lan)
	wan=$(fc_wan)
	protos=$(fc_protos)
	if fc_rules "$lan" "$wan" "$protos" &&
		nft add element inet fw4 fullcone_proto "{ $(echo $protos | tr ' ' ',') }" &&
		nft add element inet fw4 fullcone_lan "{ $lan }" &&
		nft add element inet fw4 fullcone_wan "{ \"$wan\" }"; then
		return 0
	fi
	fc_sets_flush
	$IPT -F FULLCONE_PRE 2>/dev/null
	$IPT -F FULLCONE_POST 2>/dev/null
	logger -t fullcone -p daemon.warn "apply failed (lan='$lan' wan='$wan' protos='$protos'), staying on fw4 masquerade"
	return 1
}

fc_stop() {
	local c
	fc_sets_flush
	$IPT -D PREROUTING -j FULLCONE_PRE 2>/dev/null
	$IPT -D POSTROUTING -j FULLCONE_POST 2>/dev/null
	for c in PRE POST; do
		$IPT -F FULLCONE_$c 2>/dev/null
		$IPT -X FULLCONE_$c 2>/dev/null
	done
	fc_rmmod
	return 0
}

fc_status() {
	local en=false forced=false loaded=false tcp=false mode lan wan wanip rules sets inbound="0 0"
	[ "$(fc_get enabled)" = 1 ] && en=true
	grep -q '^xt_FULLCONENAT ' /proc/modules && loaded=true
	lan=$(fc_lan)
	wan=$(fc_wan)
	rules=$($IPT -S FULLCONE_POST 2>/dev/null | grep -c FULLCONENAT)
	$IPT -S FULLCONE_POST 2>/dev/null | grep -q -e '-p tcp .*-j FULLCONENAT' && tcp=true
	sets=$(nft list set inet fw4 fullcone_wan 2>/dev/null | grep -c elements)
	if [ "$rules" -gt 0 ] && [ "$sets" -gt 0 ]; then
		mode=fullcone
		[ $en = false ] && forced=true
	elif [ "$rules" -gt 0 ] || [ "$sets" -gt 0 ]; then
		mode=broken
	elif [ $en = true ]; then
		mode=fallback
	else
		mode=disabled
	fi
	# Inbound UDP/TCP flows DNATed into the LAN: original dst is the WAN IP, reply src is not.
	wanip=$(ip -4 -o addr show dev "$wan" 2>/dev/null | awk '{ sub("/.*", "", $4); print $4; exit }')
	[ -n "$wanip" ] && inbound=$(awk -v w="$wanip" '$3 == "udp" || $3 == "tcp" {
		d = ""; r = ""; n = 0
		for (i = 4; i <= NF; i++) {
			if ($i ~ /^dst=/ && d == "") d = substr($i, 5)
			if ($i ~ /^src=/ && ++n == 2) r = substr($i, 5)
		}
		if (d == w && r != "" && r != w) c[$3]++
	} END { print c["udp"] + 0, c["tcp"] + 0 }' /proc/net/nf_conntrack)
	printf '{"enabled":%s,"forced":%s,"module_loaded":%s,"tcp":%s,"mode":"%s","lan":"%s","wan":"%s","inbound_udp":%d,"inbound_tcp":%d}\n' \
		$en $forced $loaded $tcp $mode "$lan" "$wan" "${inbound% *}" "${inbound#* }"
}

case "$1" in
""|apply) fc_apply ;;
status) fc_status ;;
stop) fc_stop ;;
*) echo "usage: $0 [apply|status|stop]" >&2; exit 1 ;;
esac
