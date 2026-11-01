# Full cone NAT (fullcone, luci-app-fullcone)

IPv4 UDP full cone NAT (NAT1) for a stock OpenWrt router with firewall4, without reflashing:
`xt_FULLCONENAT` (`kmod-ipt-fullconenat`, `iptables-mod-fullconenat`), a firewall4 include
(`fullcone`) and a LuCI page (`luci-app-fullcone`, Network → Full Cone NAT). TCP keeps the normal
masquerade. Design notes: [plan/2026-10-26-fullcone.md](plan/2026-10-26-fullcone.md).

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

## TCP NAT1 for chosen LAN endpoints

The package does UDP only. For TCP NAT1 on a LAN `ip:port`, add a stock port forward in LuCI
(Network → Firewall → Port Forwards): protocol TCP, source zone wan, external port `P`,
destination zone lan, internal IP `ip`, internal port empty (reuses `P`). Masquerade keeps the
source port, so the CGNAT mapping of `P` reaches the LAN host. Skip ports used by Docker or
`exclude_port`. Details: the TCP section of the design notes.

## Uninstall

```sh
apk del luci-app-fullcone fullcone iptables-mod-fullconenat kmod-ipt-fullconenat
```

## Limits

- The kmod only installs on the exact kernel it was built for; the feed has one build per
  `sdk/*.env`. Remove the packages before an attended sysupgrade.
- UDP sent through a proxy TUN does not get full cone.
- Mappings are reclaimed lazily; disabling unloads the module and frees them.
