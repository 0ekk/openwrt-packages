# Full cone NAT (fullcone, luci-app-fullcone)

IPv4 UDP full cone NAT (NAT1), and optionally TCP, for a stock OpenWrt router with firewall4,
without reflashing: `xt_FULLCONENAT` (`kmod-ipt-fullconenat`, `iptables-mod-fullconenat`), a
firewall4 include (`fullcone`) and a LuCI page (`luci-app-fullcone`, Network → Full Cone NAT).
Design notes: [plan/2026-10-26-fullcone.md](plan/2026-10-26-fullcone.md).

## Install

Take a VM snapshot first if the router is a VM. With the feed configured (see the README):

```sh
apk add luci-app-fullcone   # pulls fullcone and the kmod; ships disabled
```

Try it until the next firewall reload or reboot, then test from a LAN host:

```sh
FULLCONE_FORCE=1 /usr/share/fullcone/fullcone.sh; /usr/share/fullcone/fullcone.sh status
python3 test/fullcone/check_nat.py   # on a LAN host; expects "RESULT: Full Cone (NAT1)"
```

Keep it on: tick Enable in LuCI, or `uci set fullcone.main.enabled=1; uci commit fullcone; reload_config`.

An upgrade of `fullcone` unloads the old module and reloads the firewall, so the new module is
used at once; UDP falls back to plain masquerade for that moment.

## TCP

Off by default. Turn it on with the TCP switch in LuCI, or:

```sh
uci set fullcone.main.tcp=1; uci commit fullcone; reload_config
```

LAN TCP leaving the WAN device then gets the same treatment as UDP: the source port is kept when
it is free, and while a LAN host has a connection open from port `P`, anyone on the internet can
open a TCP connection to `wan:P` and reach that host. Only apps that listen on the port they
connect from (TCP hole punching, some P2P clients) make use of it; other hosts answer with a
reset. `exclude_port` applies to TCP too: add router TCP services reachable from the WAN there.

With OpenClash running, only TCP that leaves `pppoe-wan` directly gets NAT1; TCP that the proxy
carries gets the proxy's mapping. In `redir-host-tun` mode that is TCP to the China IP list
(`china_ip_route=1`) and, if `common_ports` is set, to ports outside that list. Check while the
app runs: `conntrack -L -p tcp --sport <P>` shows `src=<LAN host>` and the reply going to the
`pppoe-wan` address.

A LAN `ip:port` that must be reachable with no outbound connection open needs a normal port
forward (Network → Firewall → Port Forwards) instead.

## Kernel log

The module logs instead of failing hard; `dmesg | grep xt_FULLCONENAT` shows:

- `rejected ...`: a FULLCONENAT rule with an invalid range, IPv6, or outside the main network
  namespace was refused (the `iptables-nft` command fails, fullcone stays on masquerade).
- `no free port, falling back to plain SNAT`: every probed external port had a live mapping; that
  flow was NATed normally and has no full cone mapping.
- `no conntrack, skipping`: a packet without a conntrack entry reached the target; it was passed on.

## Uninstall

```sh
apk del luci-app-fullcone fullcone iptables-mod-fullconenat kmod-ipt-fullconenat
```

## Limits

- The kmod only installs on the exact kernel it was built for; the feed has one build per
  `sdk/*.env`. Remove the packages before an attended sysupgrade.
- UDP and TCP sent through a proxy TUN do not get full cone.
- Mappings are reclaimed lazily (at most about one per external port and protocol); disabling
  unloads the module and frees them.
