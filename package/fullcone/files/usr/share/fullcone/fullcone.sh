#!/bin/sh
# UDP (and, with option tcp, TCP) full cone NAT for fw4 via xt_FULLCONENAT (iptables-nft, table ip nat;
# with option ipv6, also NAT66 in table ip6 nat).
# fw4 sources this file as a firewall include with no arguments (= apply) after every
# start/reload; it must never call fw4 itself (fw4 holds its lock while running includes).
# Usage: fullcone.sh [apply|status|stop]; FULLCONE_FORCE=1 applies while disabled in uci.

IPT="iptables-nft -w -t nat"
# xtables-nft (pulled in by iptables-nft) is built with IPv6; the ip6tables-nft package only adds
# symlinks and kmod-ip6tables.
IPT6="xtables-nft-multi ip6tables-nft -w -t nat"

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

# The IPv6 LAN that fw4 masquerades (NAT66): the ULA prefix unless set.
fc_lan6() {
	local v
	v=$(fc_get lan6_subnet)
	[ -n "$v" ] || v=$(uci -q get network.globals.ula_prefix)
	echo "$v"
}

# Without masq6 IPv6 is routed, not NATed: there is no masquerade for full cone to replace.
fc_masq6() {
	uci -q show firewall | grep -q "\.masq6='1'"
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
	local s
	for s in fullcone_proto fullcone_lan fullcone_lan6 fullcone_wan; do
		nft flush set inet fw4 $s 2>/dev/null
	done
}

fc_rmmod() {
	grep -q '^xt_FULLCONENAT ' /proc/modules || return 0
	# nft_compat drops the target reference from a work queue after the rule flush.
	rmmod xt_FULLCONENAT 2>/dev/null || { sleep 1; rmmod xt_FULLCONENAT 2>/dev/null; }
}

# fc_chains add|del IPTABLES...: the FULLCONE_PRE/POST chains and the jumps to them.
fc_chains() {
	local op=$1 c
	shift
	for c in PRE POST; do
		if [ "$op" = add ]; then
			"$@" -N FULLCONE_$c 2>/dev/null
			"$@" -F FULLCONE_$c || return 1
			"$@" -C ${c}ROUTING -j FULLCONE_$c 2>/dev/null || "$@" -A ${c}ROUTING -j FULLCONE_$c || return 1
		else
			"$@" -D ${c}ROUTING -j FULLCONE_$c 2>/dev/null
			"$@" -F FULLCONE_$c 2>/dev/null
			"$@" -X FULLCONE_$c 2>/dev/null
		fi
	done
	return 0
}

# Only touches table ip6 nat when it exists, so IPv4-only setups never get one.
fc_chains6_del() {
	nft list table ip6 nat >/dev/null 2>&1 || return 0
	fc_chains del $IPT6
}

# fc_rules LAN WAN PROTOS IPTABLES...
fc_rules() {
	local lan=$1 wan=$2 protos=$3 proto p
	shift 3
	for proto in $protos; do
		for p in $(fc_get exclude_port); do
			"$@" -A FULLCONE_PRE -i "$wan" -p "$proto" --dport "$p" -j RETURN || return 1
		done
		"$@" -A FULLCONE_PRE -i "$wan" -p "$proto" -j FULLCONENAT &&
			"$@" -A FULLCONE_POST -o "$wan" -s "$lan" -p "$proto" -j FULLCONENAT || return 1
	done
}

fc_apply() {
	local lan wan lan6= protos
	# Sets first: an empty set makes fw4 masquerade everything again.
	fc_sets_flush
	fc_chains add $IPT
	fc_chains6_del

	if [ "$(fc_get enabled)" != 1 ] && [ "$FULLCONE_FORCE" != 1 ]; then
		fc_rmmod
		return 0
	fi

	lan=$(fc_lan)
	wan=$(fc_wan)
	protos=$(fc_protos)
	if [ "$(fc_get ipv6)" = 1 ]; then
		if ! fc_masq6; then
			logger -t fullcone -p daemon.notice "ipv6 set, but no firewall zone has masq6: IPv6 left to fw4"
		else
			lan6=$(fc_lan6)
			[ -n "$lan6" ] || logger -t fullcone -p daemon.notice \
				"ipv6 set, but no IPv6 LAN subnet (lan6_subnet, network.globals.ula_prefix): IPv6 left to fw4"
		fi
	fi
	if [ -n "$lan" ] && [ -n "$wan" ] && modprobe xt_FULLCONENAT &&
		fc_rules "$lan" "$wan" "$protos" $IPT &&
		{ [ -z "$lan6" ] || { fc_chains add $IPT6 && fc_rules "$lan6" "$wan" "$protos" $IPT6 &&
			nft add element inet fw4 fullcone_lan6 "{ $lan6 }"; }; } &&
		nft add element inet fw4 fullcone_proto "{ $(echo $protos | tr ' ' ',') }" &&
		nft add element inet fw4 fullcone_lan "{ $lan }" &&
		nft add element inet fw4 fullcone_wan "{ \"$wan\" }"; then
		return 0
	fi
	fc_sets_flush
	$IPT -F FULLCONE_PRE 2>/dev/null
	$IPT -F FULLCONE_POST 2>/dev/null
	fc_chains6_del
	logger -t fullcone -p daemon.warn \
		"apply failed (lan='$lan' lan6='$lan6' wan='$wan' protos='$protos'), staying on fw4 masquerade"
	return 1
}

fc_stop() {
	fc_sets_flush
	fc_chains del $IPT
	fc_chains6_del
	fc_rmmod
	return 0
}

# Inbound UDP/TCP flows DNATed into the LAN, both families: the original destination is a WAN
# address and the reply comes from elsewhere. Prints the JSON members inbound_udp, inbound_tcp and
# flows (at most 100 per protocol). /proc/net/nf_conntrack prints IPv6 uncompressed (%pI6), so the
# WAN's IPv6 addresses are taken from /proc/net/if_inet6 in the same form.
fc_inbound() {
	local wan=$1 w4 w6
	w4=$(ip -4 -o addr show dev "$wan" 2>/dev/null | awk '{ sub("/.*", "", $4); print $4 }')
	w6=$(awk -v d="$wan" '$6 == d && $4 == "00" {
		a = substr($1, 1, 4); for (i = 5; i < 32; i += 4) a = a ":" substr($1, i, 4); print a }' /proc/net/if_inet6 2>/dev/null)
	awk -v w="$w4 $w6" -v max=100 'BEGIN { n = split(w, a, " "); for (i = 1; i <= n; i++) wan[a[i]] = 1 }
	$3 == "udp" || $3 == "tcp" {
		s1 = d1 = sp1 = dp1 = s2 = sp2 = ""
		for (i = 4; i <= NF; i++) {
			e = index($i, "=")
			if (!e) continue
			k = substr($i, 1, e - 1); v = substr($i, e + 1)
			if (k == "src") { if (s1 == "") s1 = v; else if (s2 == "") s2 = v }
			else if (k == "sport") { if (sp1 == "") sp1 = v; else if (sp2 == "") sp2 = v }
			else if (k == "dst" && d1 == "") d1 = v
			else if (k == "dport" && dp1 == "") dp1 = v
		}
		if (!(d1 in wan) || s2 == "" || s2 == d1) next
		if (++c[$3] <= max)
			f = f (f == "" ? "" : ",") sprintf("{\"proto\":\"%s\",\"remote\":\"%s\",\"rport\":%d,\"port\":%d,\"lan\":\"%s\",\"lport\":%d,\"timeout\":%d}",
				$3, s1, sp1, dp1, s2, sp2, $5)
	}
	END { printf "\"inbound_udp\":%d,\"inbound_tcp\":%d,\"flows\":[%s]", c["udp"], c["tcp"], f }' /proc/net/nf_conntrack 2>/dev/null
}

fc_status() {
	local en=false forced=false loaded=false tcp=false ipv6=off mode lan lan6 wan rules sets inbound
	[ "$(fc_get enabled)" = 1 ] && en=true
	grep -q '^xt_FULLCONENAT ' /proc/modules && loaded=true
	lan=$(fc_lan)
	lan6=$(fc_lan6)
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
	if nft list chain ip6 nat FULLCONE_POST 2>/dev/null | grep -q FULLCONENAT; then
		ipv6=active
	elif [ "$(fc_get ipv6)" = 1 ]; then
		ipv6=inactive
	fi
	inbound=$(fc_inbound "$wan")
	[ -n "$inbound" ] || inbound='"inbound_udp":0,"inbound_tcp":0,"flows":[]'
	printf '{"enabled":%s,"forced":%s,"module_loaded":%s,"tcp":%s,"ipv6":"%s","mode":"%s","lan":"%s","lan6":"%s","wan":"%s",%s}\n' \
		$en $forced $loaded $tcp $ipv6 $mode "$lan" "$lan6" "$wan" "$inbound"
}

case "$1" in
""|apply) fc_apply ;;
status) fc_status ;;
stop) fc_stop ;;
*) echo "usage: $0 [apply|status|stop]" >&2; exit 1 ;;
esac
