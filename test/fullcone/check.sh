# Full cone assertions, sourced by `test/lab.sh check` (vm, ok, fail and TOP come from lab.sh).
NAT="ip netns exec fcl-lan python3 -I $TOP/test/fullcone/check_nat.py 203.0.113.1:3478"

vm 'uci set fullcone.main.enabled=0 && uci commit fullcone && /etc/init.d/firewall reload 2>/dev/null; dmesg -c >/dev/null'

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

vm 'dmesg' | grep -q -E 'WARNING|BUG|Oops' && fail "kernel warning in dmesg"
ok "dmesg clean"

vm 'uci set fullcone.main.enabled=0 && uci commit fullcone && reload_config && sleep 3'
vm 'grep -q "^xt_FULLCONENAT " /proc/modules' && fail "disabled: module still loaded"
! $NAT >/dev/null || fail "disabled again: still full cone"
ok "disabled again: module unloaded, stock masquerade"
