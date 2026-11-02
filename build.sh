#!/bin/sh
# Build every package in package/ with the official OpenWrt SDK described by an sdk/*.env file
# and add the upstream release files listed in prebuilt.list.
# Usage: ./build.sh [sdk/<release>-<target>.env]   (default: the newest file in sdk/)
# Output: out/*.apk. MIRROR changes the download host (e.g. https://mirrors.ustc.edu.cn/openwrt).
# Verbose build: V=s ./build.sh
set -eu

TOP=$(cd "$(dirname "$0")" && pwd)
ENV=${1:-$(ls "$TOP"/sdk/*.env | sort -V | tail -n 1)}
. "$(cd "$(dirname "$ENV")" && pwd)/${ENV##*/}"
MIRROR=${MIRROR:-https://downloads.openwrt.org}
B=$TOP/.build
S=$B/$SDK
mkdir -p "$B/dl"

if [ ! -d "$S" ]; then
	f=$B/dl/$SDK.tar.zst
	[ -f "$f" ] || curl -fL --retry 3 -o "$f" "$MIRROR/releases/$REL/targets/$TARGET/$SDK.tar.zst"
	echo "$SDK_SHA256  $f" | sha256sum -c -
	tar --zstd -xf "$f" -C "$B"
fi

# Kernel gate: kmods get "kernel=<version>~<vermagic>-r<release>"; the SDK must carry that vermagic.
magic=${KERNEL_PIN#*~}
magic=${magic%-r*}
grep -q "$magic" "$S/include/kernel.mk" || { echo "SDK kernel does not match $KERNEL_PIN" >&2; exit 1; }

# The base feed (build dependencies such as iptables) at the commit the SDK was released with.
BASE_REV=$(sed -n 's/^src-git .* base .*\^//p' "$S/feeds.conf.default")
BASE=$B/dl/openwrt-${BASE_REV:?no base feed commit in feeds.conf.default}
[ -d "$BASE" ] || curl -fL --retry 3 "https://codeload.github.com/openwrt/openwrt/tar.gz/$BASE_REV" | tar -xz -C "$B/dl"

cd "$S"
# package/ is a feed of its own: installing it pulls build dependencies (e.g. iptables) from base.
printf 'src-link base %s/package\nsrc-link local %s/package\n' "$BASE" "$TOP" > feeds.conf
./scripts/feeds update -a
./scripts/feeds install -a -p local
PKGS=$(./scripts/feeds list -r local | awk '{ print $1 }')
{
	# Only build our packages and their dependencies instead of every kmod in the SDK.
	echo "# CONFIG_ALL_KMODS is not set"
	echo "# CONFIG_ALL_NONSHARED is not set"
	for p in $PKGS; do echo "CONFIG_PACKAGE_$p=m"; done
} > .config
make defconfig
rm -rf bin
for d in "$TOP"/package/*/; do
	d=${d%/}
	make -j"$(nproc)" "package/feeds/local/${d##*/}/compile"
done

rm -rf "$TOP/out"
mkdir "$TOP/out"
for p in $PKGS; do
	find bin -name "$p-[0-9]*.apk" -exec cp {} "$TOP/out/" \;
	ls "$TOP/out/$p-"[0-9]*.apk >/dev/null 2>&1 || { echo "no apk built for $p" >&2; exit 1; }
done
sed '/^#/d;/^$/d' "$TOP/prebuilt.list" | while read -r sum url; do
	f=$B/dl/${url##*/}
	[ -f "$f" ] || curl -fL --retry 3 -o "$f" "$url"
	echo "$sum  $f" | sha256sum -c -
	cp "$f" "$TOP/out/"
done
for k in "$TOP"/out/kmod-*.apk; do
	[ -e "$k" ] || continue
	staging_dir/host/bin/apk adbdump "$k" | grep -qxF "    - kernel=$KERNEL_PIN" ||
		{ echo "${k##*/} does not depend on kernel=$KERNEL_PIN" >&2; exit 1; }
done
ls -l "$TOP/out"
