#!/bin/sh
# Build the fullcone packages with the official OpenWrt SDK whose kernel matches the router.
# Output: out/*.apk. Verbose build: V=s ./build.sh
set -eu

ROUTER=${ROUTER:-root@192.168.1.1}
REL=25.12.5
SDK=openwrt-sdk-$REL-x86-64_gcc-14.3.0_musl.Linux-x86_64
# From https://downloads.openwrt.org/releases/25.12.5/targets/x86/64/sha256sums
SDK_SHA256=0c8df0151a1e88feb7c03d694d61f6a18d51872815b7c811d76e2b77504d5e9c
SDK_URL=${SDK_URL:-https://mirrors.ustc.edu.cn/openwrt/releases/$REL/targets/x86/64/$SDK.tar.zst}
# Base feed commit from the SDK's feeds.conf.default (provides iptables/libxtables).
BASE_REV=f0a60eee2fe051741c643ea6118718aae1ef17fb

TOP=$(cd "$(dirname "$0")" && pwd)
B=$TOP/.build
S=$B/$SDK
BASE=$B/dl/openwrt-$BASE_REV
mkdir -p "$B/dl"

if [ ! -d "$S" ]; then
	f=$B/dl/$SDK.tar.zst
	[ -f "$f" ] || curl -fL --retry 3 -o "$f" "$SDK_URL"
	echo "$SDK_SHA256  $f" | sha256sum -c -
	tar --zstd -xf "$f" -C "$B"
fi

# Kernel gate: kmods get "kernel=<version>~<vermagic>-r<release>" and must match the router's pin.
PIN=${KERNEL_PIN:-$(ssh -T -o BatchMode=yes -o ConnectTimeout=5 "$ROUTER" "sed -n 's/^kernel=//p' /etc/apk/world")}
magic=${PIN#*~}
magic=${magic%-r*}
grep -q "$magic" "$S/include/kernel.mk" || { echo "SDK kernel does not match router pin $PIN" >&2; exit 1; }

[ -d "$BASE" ] || curl -fL --retry 3 "https://codeload.github.com/openwrt/openwrt/tar.gz/$BASE_REV" | tar -xz -C "$B/dl"

cd "$S"
echo "src-link base $BASE/package" > feeds.conf
./scripts/feeds update base
./scripts/feeds install -p base iptables
for p in "$TOP"/package/*; do ln -sfn "$p" "package/${p##*/}"; done
{
	# Only build what we need instead of every kmod in the SDK.
	echo "# CONFIG_ALL_KMODS is not set"
	echo "# CONFIG_ALL_NONSHARED is not set"
	for p in kmod-ipt-fullconenat iptables-mod-fullconenat fullcone luci-app-fullcone; do
		echo "CONFIG_PACKAGE_$p=m"
	done
} >> .config
make defconfig
find bin -name '*fullcone*.apk' -delete 2>/dev/null || true
for p in "$TOP"/package/*; do make -j"$(nproc)" "package/${p##*/}/compile"; done

rm -rf "$TOP/out"
mkdir "$TOP/out"
find bin -name '*fullcone*.apk' -exec cp {} "$TOP/out/" \;
staging_dir/host/bin/apk adbdump "$TOP"/out/kmod-ipt-fullconenat-*.apk | grep -qxF "    - kernel=$PIN" ||
	{ echo "kmod does not depend on kernel=$PIN" >&2; exit 1; }
ls -l "$TOP/out"
