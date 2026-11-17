# Full cone assertions, sourced by `test/lab.sh check` (vm, ok, fail and TOP come from lab.sh).
NAT="ip netns exec fcl-lan python3 -I $TOP/test/fullcone/check_nat.py 203.0.113.1:3478"
# Runs on the lab host and enters both netns; each run takes its own LAN port (TIME_WAIT).
TCPNAT="python3 -I $TOP/test/fullcone/check_tcp.py"

vm 'uci set fullcone.main.enabled=0 && uci set fullcone.main.tcp=0 && uci commit fullcone && /etc/init.d/firewall reload 2>/dev/null; dmesg -c >/dev/null'

! $NAT >/dev/null || fail "disabled but already full cone"
ok "disabled: not full cone"

vm 'FULLCONE_FORCE=1 /usr/share/fullcone/fullcone.sh'
vm '/usr/share/fullcone/fullcone.sh status' | grep -q '"mode":"fullcone"' || fail "forced: mode is not fullcone"
$NAT >/dev/null || fail "forced: not full cone"
ok "forced: full cone"

vm 'uci set fullcone.main.enabled=1 && uci commit fullcone && reload_config && sleep 3 && /etc/init.d/firewall reload 2>/dev/null'
$NAT >/dev/null || fail "enabled + firewall reload: not full cone"
vm 'conntrack -L -p udp 2>/dev/null' | grep -q 'src=203.0.113.2 .*\[UNREPLIED\] src=192.168.1.100' ||
	fail "no inbound DNAT entry from the STUN alternate address"
ok "enabled: full cone across firewall reload, inbound DNAT seen"

! $TCPNAT 40400 >/dev/null || fail "tcp off: TCP already full cone"
ok "tcp off: TCP keeps masquerade"

vm 'uci set fullcone.main.tcp=1 && uci commit fullcone && reload_config && sleep 3'
vm '/usr/share/fullcone/fullcone.sh status' | grep -q '"tcp":true' || fail "tcp on: status does not report tcp"
$TCPNAT 40410 >/dev/null || fail "tcp on: not TCP full cone"
vm 'conntrack -L -p tcp 2>/dev/null' | grep -q 'src=203.0.113.2 .*src=192.168.1.100' ||
	fail "tcp on: no inbound TCP DNAT entry"
$NAT >/dev/null || fail "tcp on: UDP no longer full cone"
ok "tcp on: TCP and UDP full cone, inbound TCP DNAT seen"

# As on the router: established flows are offloaded and skip the nft chains.
vm 'uci set firewall.@defaults[0].flow_offloading=1 && uci commit firewall && /etc/init.d/firewall reload 2>/dev/null'
vm 'nft list flowtables' | grep -q 'flowtable ft' || fail "flow offloading did not load"
$TCPNAT 40415 >/dev/null || fail "tcp on + flow offloading: not TCP full cone"
vm 'uci -q delete firewall.@defaults[0].flow_offloading; uci commit firewall && /etc/init.d/firewall reload 2>/dev/null'
ok "tcp on + flow offloading: TCP full cone"

# Rules the old module accepted: 0-65535 wrapped its u16 port range to 0 (division by zero with
# --random); an inverted --to-source range. Both must now be rejected with a log line.
vm 'iptables-nft -w -t nat -A FULLCONE_POST -o pppoe-wan -p udp -j FULLCONENAT --to-ports 0-65535 --random' 2>/dev/null &&
	fail "--to-ports 0-65535 accepted"
vm 'iptables-nft -w -t nat -A FULLCONE_POST -o pppoe-wan -p udp -j FULLCONENAT --to-source 100.64.0.20-100.64.0.10' 2>/dev/null &&
	fail "inverted --to-source accepted"
vm 'dmesg' | grep -q 'xt_FULLCONENAT: rejected invalid port range 0-65535' || fail "no log line for the port range"
vm 'dmesg' | grep -q 'xt_FULLCONENAT: rejected inverted IP range' || fail "no log line for the IP range"
ok "invalid ranges rejected with a log line"

# No free port: three flows, a two-port range. The third gets plain SNAT in the range, no mapping.
R='-o pppoe-wan -s 192.168.1.100 -d 203.0.113.1 -p udp -j FULLCONENAT --to-ports 40000-40001'
vm "iptables-nft -w -t nat -I FULLCONE_POST $R"
ip netns exec fcl-lan python3 -I -c 'import socket
for i in range(3):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.bind(("192.168.1.100", 41000 + i))
    s.sendto(b"x", ("203.0.113.1", 7 + i))
    s.close()'
n=$(vm 'conntrack -L -p udp 2>/dev/null' | grep -cE 'sport=4100[012] dport=[789] .*dport=4000[01] ' || true)
vm "iptables-nft -w -t nat -D FULLCONE_POST $R"
[ "$n" = 3 ] || fail "no free port: $n of 3 flows SNATed into 40000-40001"
vm 'dmesg' | grep -q 'xt_FULLCONENAT: no free port, falling back to plain SNAT' || fail "no log line for the full range"
ok "no free port: plain SNAT in the rule's range, logged"

vm 'dmesg' | grep -q -E 'WARNING|BUG|Oops' && fail "kernel warning in dmesg"
ok "dmesg clean"

vm 'uci set fullcone.main.tcp=0 && uci commit fullcone && reload_config && sleep 3'
vm 'nft list set inet fw4 fullcone_proto' | grep -q tcp && fail "tcp off again: tcp still in fullcone_proto"
! $TCPNAT 40420 >/dev/null || fail "tcp off again: still TCP full cone"
ok "tcp off again: TCP keeps masquerade"

vm 'uci set fullcone.main.enabled=0 && uci commit fullcone && reload_config && sleep 3'
vm 'grep -q "^xt_FULLCONENAT " /proc/modules' && fail "disabled: module still loaded"
! $NAT >/dev/null || fail "disabled again: still full cone"
ok "disabled again: module unloaded, stock masquerade"
