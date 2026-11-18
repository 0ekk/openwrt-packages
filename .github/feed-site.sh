#!/bin/sh
# Lays out and signs the feeds of one SDK build: the feed workflow's sign step, also run by hand
# with a throwaway key (KEYS_DIR = its public half) to test the layout.
# Usage, from the repository root after ./build.sh SDK_ENV filled out/:
#   APK_SIGN_KEY=<private key PEM> .github/feed-site.sh SDK_ENV SITE
#   SITE/<release>/packages/<arch>/packages/  kernel-independent packages
#   SITE/<release>/packages/<arch>/luci/      LuCI packages (luci-*)
#   SITE/<release>/targets/<target>/          kmods: they only install on this target's kernel
# Each directory gets packages.adb (signed, then verified against KEYS_DIR, default keys/) and
# index.json (unsigned package list, as the SDK makes it; owut reads it). The key file only
# exists while apk signs; the SDK's scripts run after it is deleted.
set -eu
TOP=$(pwd)
case $1 in /*) . "$1" ;; *) . "./$1" ;; esac
site=$2
sdk=$TOP/.build/$SDK
apk=$sdk/staging_dir/host/bin/apk
keys=${KEYS_DIR:-$TOP/keys}
arch=$(sed -n 's/^CONFIG_TARGET_ARCH_PACKAGES="\(.*\)"/\1/p' "$sdk/.config")
[ -n "$arch" ] || { echo "no CONFIG_TARGET_ARCH_PACKAGES in $sdk/.config" >&2; exit 1; }

pkgs= luci= kmods=
for f in "$TOP"/out/*.apk; do
	case ${f##*/} in
	kmod-*) kmods="$kmods $f" ;;
	luci-*) luci="$luci $f" ;;
	*) pkgs="$pkgs $f" ;;
	esac
done
[ -n "$pkgs$luci$kmods" ] || { echo "no packages in out/" >&2; exit 1; }
feeds=
[ -z "$pkgs" ] || feeds="$feeds $REL/packages/$arch/packages"
[ -z "$luci" ] || feeds="$feeds $REL/packages/$arch/luci"
[ -z "$kmods" ] || feeds="$feeds $REL/targets/$TARGET"

key=$(mktemp)
trap 'rm -f "$key"' EXIT
printf '%s\n' "$APK_SIGN_KEY" > "$key"
# Word splitting is intended: the paths come from out/ and sdk/*.env and contain no spaces.
for f in $feeds; do
	case $f in
	*/packages/$arch/packages) set -- $pkgs ;;
	*/packages/$arch/luci) set -- $luci ;;
	*) set -- $kmods ;;
	esac
	mkdir -p "$site/$f"
	cp "$@" "$site/$f/"
	(cd "$site/$f" && "$apk" mkndx --allow-untrusted --sign "$key" --output packages.adb ./*.apk)
done
rm -f "$key"

for f in $feeds; do
	"$apk" --keys-dir "$keys" verify "$site/$f/packages.adb"
	"$apk" adbdump --format json "$site/$f/packages.adb" |
		"$sdk/scripts/make-index-json.py" -f apk -a "$arch" - > "$site/$f/index.json"
	jq -e '.packages | length > 0' "$site/$f/index.json" >/dev/null
done
