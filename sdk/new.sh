#!/bin/sh
# Write sdk/<release>-<target>.env for an official release, from its download directory.
# Usage: sdk/new.sh <release> <target>   e.g. sdk/new.sh 25.12.6 x86/64
# MIRROR changes the download host (e.g. https://mirrors.ustc.edu.cn/openwrt).
set -eu

REL=$1
TARGET=$2
url=${MIRROR:-https://downloads.openwrt.org}/releases/$REL/targets/$TARGET
# shellcheck disable=SC2046 # "<sha256> <sdk name>", split on purpose
set -- $(curl -fsS "$url/sha256sums" | sed -n 's/^\([0-9a-f]\{64\}\) \*\(openwrt-sdk-.*\)\.tar\.zst$/\1 \2/p')
[ $# -eq 2 ] || { echo "no single SDK in $url/sha256sums" >&2; exit 1; }
# kmods/<version>-<release>-<vermagic>/ holds the kmods for kernel <version>~<vermagic>-r<release>.
pin=$(curl -fsS "$url/kmods/" | sed -n 's|.*href="\([0-9.]*\)-\([0-9]*\)-\([0-9a-f]\{32\}\)/".*|\1~\3-r\2|p')
case $pin in "" | *[!0-9a-z.~-]*) echo "no single kernel in $url/kmods/" >&2; exit 1 ;; esac

f=$(dirname "$0")/$REL-$(echo "$TARGET" | tr / -).env
cat > "$f" <<EOF
# Official OpenWrt SDK for one release and target, written by sdk/new.sh; build.sh sources it.
REL=$REL
TARGET=$TARGET
SDK=$2
# From the release's sha256sums
SDK_SHA256=$1
# Every kmod must depend on exactly this kernel (the release's kmods/ directory; the "kernel="
# line in /etc/apk/world on a router running the release).
KERNEL_PIN=$pin
EOF
echo "$f"
