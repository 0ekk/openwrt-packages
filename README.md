# openwrt-fullcone

IPv4 UDP full cone NAT (NAT1) for a stock OpenWrt 25.12.5 x86/64 router with firewall4, without
reflashing: `xt_FULLCONENAT` built with the official SDK, a firewall4 include, and a LuCI page
(Network → Full Cone NAT). TCP keeps the normal masquerade. Design notes:
[docs/plan/2026-10-26-fullcone.md](docs/plan/2026-10-26-fullcone.md).

## Build

```sh
./build.sh            # downloads + verifies the SDK, checks the router's kernel pin, writes out/*.apk
```

`ROUTER=root@host` changes the router (default: OpenWrt's `root@192.168.1.1`, also for `install.sh`); `KERNEL_PIN=...` skips the SSH lookup.

## Test in QEMU first

```sh
test/lab.sh up        # official image + PPPoE ISP + RFC 5780 STUN server, all in netns (root, KVM)
test/lab.sh check     # installs out/*.apk, asserts disabled/forced/enabled/reload/disable behavior
test/lab.sh down
```

Needs `qemu-system-x86_64` (Arch: `qemu-base`) and `pppoe-server` (`rp-pppoe`).

## Install

Take a VM snapshot first. Then:

```sh
./install.sh          # apk add --simulate, then apk add --allow-untrusted; ships disabled
```

Try it until the next firewall reload or reboot:

```sh
ssh root@<router> 'FULLCONE_FORCE=1 /usr/share/fullcone/fullcone.sh; /usr/share/fullcone/fullcone.sh status'
python3 check_nat.py  # from a LAN host; expects "RESULT: Full Cone (NAT1)"
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

- After a firmware upgrade the kmod no longer matches the kernel: rebuild with the new SDK.
  Remove the packages before an attended sysupgrade.
- UDP sent through a proxy TUN does not get full cone.
- Mappings are reclaimed lazily; disabling unloads the module and frees them.
