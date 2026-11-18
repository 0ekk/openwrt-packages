# Full cone NAT (fullcone, luci-app-fullcone)

UDP full cone NAT (NAT1) for IPv4, optionally TCP and masqueraded IPv6 (NAT66), for a stock OpenWrt
router with firewall4, without reflashing: `xt_FULLCONENAT` (`kmod-ipt-fullconenat`,
`iptables-mod-fullconenat`), a firewall4 include (`fullcone`) and a LuCI page
(`luci-app-fullcone`, Network → Full Cone NAT).
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

Keep it on: tick Enable in LuCI, or `uci set fullcone.main.enabled=1; uci commit fullcone; /etc/init.d/fullcone reload`.
Apply shell changes with `/etc/init.d/fullcone reload`, not `reload_config`: `reload_config` only
acts on changes since its own last run, so it does nothing the first time after a boot and misses a
change that undoes one made in LuCI.

The LuCI status counts the inbound UDP and TCP flows that reach the LAN (full cone mappings and
port forwards, both families). Click a count to list them: remote address, WAN port, LAN host and
the seconds until conntrack expires the flow, at most 100 per protocol. The list stays open across
the 5 s refresh. The same data is in `fullcone.sh status` (`flows`; IPv6 addresses uncompressed).

An upgrade of `fullcone` unloads the old module and reloads the firewall, so the new module is
used at once; UDP falls back to plain masquerade for that moment.

## TCP

Off by default. Turn it on with the TCP switch in LuCI, or:

```sh
uci set fullcone.main.tcp=1; uci commit fullcone; /etc/init.d/fullcone reload
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

## IPv6 (NAT66)

Only for a router that masquerades IPv6: `masq6` on the wan zone, typically because the ISP gives
no prefix to delegate and the LAN uses ULA addresses. With a delegated prefix the LAN hosts have
public addresses, nothing is NATed, and this option changes nothing (inbound IPv6 is then a
firewall rule question, not NAT). Off by default; turn it on with the IPv6 (NAT66) switch in LuCI, or:

```sh
uci set fullcone.main.ipv6=1; uci commit fullcone; /etc/init.d/fullcone reload
```

IPv6 from the LAN subnet (`lan6_subnet`, default `network.globals.ula_prefix`) leaving the WAN
device then gets the same UDP (and, with `tcp`, TCP) full cone as IPv4, on the router's WAN IPv6
address. Without any `masq6` zone, or without a subnet, IPv6 is left to fw4: the LuCI status says
"inactive" and the system log says why. With OpenClash proxying IPv6 (`ipv6_enable=1`), only IPv6
that leaves `pppoe-wan` directly gets full cone, as for IPv4.

## Kernel log

The module logs instead of failing hard; `dmesg | grep xt_FULLCONENAT` shows:

- `rejected ...`: a FULLCONENAT rule with an invalid port or address range (`... IPv6 ...` for an
  ip6tables rule), or outside the main network namespace, was refused (the `iptables-nft` command
  fails, fullcone stays on masquerade).
- `no free port, falling back to plain SNAT` (`no free IPv6 port, ...` for NAT66): every probed
  external port had a live mapping; that flow was NATed normally and has no full cone mapping.
- `no conntrack, skipping`: a packet without a conntrack entry reached the target; it was passed on.

## Uninstall

```sh
apk del luci-app-fullcone fullcone iptables-mod-fullconenat kmod-ipt-fullconenat
```

## Limits

- The kmod only installs on the exact kernel it was built for; the feed has one build per
  `sdk/*.env`. Remove the packages before an attended sysupgrade.
- UDP and TCP sent through a proxy TUN do not get full cone.
- IPv6 full cone needs fw4 to masquerade IPv6 (`masq6`); routed IPv6 is never touched.
- Switching full cone, TCP or IPv6 off stops new inbound flows at once. Inbound connections
  already open, and UDP flows that keep sending, go on until they close or go idle: conntrack keeps
  their NAT, and a firewall reload does not end them. A reboot does.
- Mappings are reclaimed lazily (at most about one per external port and protocol); disabling
  unloads the module and frees them.
- Anyone can open new flows to a mapped port, and each one is tracked. A flood therefore fills the
  conntrack table as it would with a port forward. The module's own cost per new flow is constant
  (since `kmod-ipt-fullconenat` r6).
