#!/bin/sh
# QEMU lab: the official OpenWrt image behind a PPPoE "ISP" with an RFC 5780 STUN server.
# IPv6 is NAT66 (fw4 masq6): ULA LAN fd00:1::/48, WAN 2001:db8:a::10, "internet" 2001:db8:b::/64.
# No bridges (host br_netfilter/forward rules stay out of the way): the VM's LAN tap is
# moved into netns fcl-lan as the LAN client, its WAN tap into netns fcl-wan as the ISP.
# Usage (root): test/lab.sh up | check | down. `check` installs out/*.apk and sources every
# test/<package>/check.sh. MIRROR changes the download host. Needs qemu-system-x86_64, pppoe-server.
set -eu

REL=25.12.5
IMG=openwrt-$REL-x86-64-generic-ext4-combined.img.gz
IMG_SHA256=23e2538e8ab0eb52dfed1c65d608ecdb71ffd432dd54885da138ae67cd9e4461
TOP=$(cd "$(dirname "$0")/.." && pwd)
D=$TOP/.build/lab
SSH="ssh -T -i $D/key -p 2222 -o BatchMode=yes -o ControlMaster=no -o ControlPath=none
	-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR root@127.0.0.1"
MIRROR=${MIRROR:-https://downloads.openwrt.org}

vm() {
	$SSH "$@"
}

up() {
	mkdir -p "$D"
	[ -f "$D/$IMG" ] || curl -fL -o "$D/$IMG" "$MIRROR/releases/$REL/targets/x86/64/$IMG"
	echo "$IMG_SHA256  $D/$IMG" | sha256sum -c -
	gunzip -c "$D/$IMG" > "$D/openwrt.img" 2>/dev/null || true
	# The root fills a 2 GB disk: the image's ~100 MB root is too small for packages such as
	# luci-app-openclash. A sysupgrade still writes the small partition table back.
	truncate -s 2G "$D/openwrt.img"
	echo ', +' | sfdisk -q -N 2 "$D/openwrt.img"
	[ -f "$D/key" ] || ssh-keygen -q -t ed25519 -N '' -C fullcone-lab -f "$D/key"

	l=$(losetup -f --show -o $(($(partx -g -o START -n 2 "$D/openwrt.img") * 512)) "$D/openwrt.img")
	resize2fs -f "$l" >/dev/null
	mkdir -p "$D/mnt"
	mount "$l" "$D/mnt"
	install -D -m 600 "$D/key.pub" "$D/mnt/etc/dropbear/authorized_keys"
	# mgmt (QEMU user net) keeps the default route for apk; the lab "internet" is routed via pppoe-wan.
	cat > "$D/mnt/etc/uci-defaults/99-lab" <<-EOF
	uci batch <<EOT
	set network.mgmt=interface
	set network.mgmt.proto=dhcp
	set network.mgmt.device=eth2
	add_list firewall.@zone[0].network=mgmt
	set network.wan.proto=pppoe
	set network.wan.username=lab
	set network.wan.password=lab
	set network.wan.defaultroute=0
	add network route
	set network.@route[-1].interface=wan
	set network.@route[-1].target=203.0.113.0/24
	set network.wan.ipv6=1
	set network.wan6.proto=static
	set network.wan6.device=@wan
	set network.wan6.ip6addr=2001:db8:a::10/64
	add network route6
	set network.@route6[-1].interface=wan6
	set network.@route6[-1].target=2001:db8:b::/64
	set network.globals.ula_prefix=fd00:1::/48
	set firewall.@zone[1].masq6=1
	commit
	EOT
	sed -i 's#https://downloads.openwrt.org#$MIRROR#' /etc/apk/repositories.d/distfeeds.list
	exit 0
	EOF
	umount "$D/mnt"
	losetup -d "$l"

	for t in fcl-tap0 fcl-tap1; do
		ip tuntap add "$t" mode tap
		ip link set "$t" up
	done
	qemu-system-x86_64 -enable-kvm -cpu host -smp 2 -m 1024 -display none -daemonize \
		-pidfile "$D/qemu.pid" -serial "file:$D/console.log" \
		-drive "file=$D/openwrt.img,format=raw,if=virtio" \
		-netdev tap,id=n0,ifname=fcl-tap0,script=no,downscript=no -device virtio-net-pci,netdev=n0 \
		-netdev tap,id=n1,ifname=fcl-tap1,script=no,downscript=no -device virtio-net-pci,netdev=n1 \
		-netdev user,id=n2,hostfwd=tcp:127.0.0.1:2222-:22 -device virtio-net-pci,netdev=n2

	ip netns add fcl-lan
	ip netns add fcl-wan
	ip link set fcl-tap0 netns fcl-lan
	ip link set fcl-tap1 netns fcl-wan
	ip -n fcl-lan link set lo up
	ip -n fcl-lan link set fcl-tap0 up
	ip -n fcl-lan addr add 192.168.1.100/24 dev fcl-tap0
	ip -n fcl-lan route add default via 192.168.1.1
	ip -n fcl-lan addr add fd00:1::100/64 dev fcl-tap0 nodad
	ip -n fcl-lan route add 2001:db8:b::/64 via fd00:1::1
	ip -n fcl-wan link set lo up
	ip -n fcl-wan link set fcl-tap1 up
	ip -n fcl-wan addr add 203.0.113.1/32 dev lo
	ip -n fcl-wan addr add 203.0.113.2/32 dev lo
	ip -n fcl-wan addr add 2001:db8:b::1/128 dev lo
	ip -n fcl-wan addr add 2001:db8:b::2/128 dev lo
	# User-mode PPPoE: rp-pppoe's kernel-mode plugin breaks whenever pppd is upgraded.
	printf 'noauth\nlcp-echo-interval 10\nlcp-echo-failure 3\nmtu 1492\nmru 1492\nnodefaultroute\n+ipv6\n' > "$D/pppoe-options"
	ip netns exec fcl-wan pppoe-server -I fcl-tap1 -L 100.64.0.1 -R 100.64.0.10 -N 4 -O "$D/pppoe-options"
	ip netns exec fcl-wan python3 -I "$TOP/test/stun_server.py" 203.0.113.1 203.0.113.2 >/dev/null 2>&1 &

	i=0
	until vm 'ifstatus wan | jsonfilter -e @.up; ifstatus wan6 | jsonfilter -e @.up' 2>/dev/null | grep -c true | grep -q 2; do
		i=$((i + 1))
		[ $i -lt 60 ] || { echo "VM or PPPoE did not come up" >&2; exit 1; }
		sleep 2
	done
	ip -n fcl-wan route add 2001:db8:a::/64 dev "$(ip -n fcl-wan -o link | awk -F': ' '$2 ~ /^ppp/ { print $2; exit }')"
	# nlbwmon makes ctnetlink load at boot, as on a router that does traffic accounting.
	vm 'apk update >/dev/null && apk add nlbwmon conntrack >/dev/null && /etc/init.d/nlbwmon enable && /etc/init.d/nlbwmon start'
	echo "lab up; shell: ssh -i $D/key -p 2222 root@127.0.0.1"
}

ok() {
	echo "PASS: $*"
}

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

check() {
	(cd "$TOP/out" && tar -cf - ./*.apk) | vm 'rm -rf /tmp/pkgs && mkdir /tmp/pkgs && tar -xf - -C /tmp/pkgs &&
		apk add --allow-untrusted /tmp/pkgs/*.apk >/dev/null'
	for t in "$TOP"/test/*/check.sh; do
		echo "== ${t#"$TOP"/}"
		. "$t"
	done
}

down() {
	[ -f "$D/qemu.pid" ] && kill "$(cat "$D/qemu.pid")" 2>/dev/null || true
	for n in fcl-lan fcl-wan; do
		ip netns pids "$n" 2>/dev/null | xargs -r kill
		ip netns del "$n" 2>/dev/null || true
	done
	ip link del fcl-tap0 2>/dev/null || true
	ip link del fcl-tap1 2>/dev/null || true
	rm -f "$D/qemu.pid" "$D/openwrt.img"
}

case "${1:-}" in
up|check|down) "$1" ;;
*) echo "usage: $0 up|check|down" >&2; exit 1 ;;
esac
