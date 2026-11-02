# Firmware upgrade with feed and third-party packages

Procedure for moving a router to a new OpenWrt release when it runs packages from this feed and
packages installed from `.apk` files that are in no feed. Rehearsed in QEMU from 25.12.5 to
25.12.6 on x86/64 ext4 with the root partition grown by the
[expand-root](https://openwrt.org/docs/guide-user/advanced/expand_root) uci-defaults scripts;
results in [plan/2026-11-02-firmware-upgrade.md](plan/2026-11-02-firmware-upgrade.md).

## What goes wrong otherwise

- `sysupgrade.openwrt.org` rejects custom feeds (`Repository not allowed`), so an attended
  sysupgrade image cannot contain feed packages, and files-only packages are in no feed at all.
- A large package set does not fit the default root size of the image (`Selected packages
  exceed device storage`); a bigger root (`owut -S`) can exceed the server's build time limit.
- sysupgrade writes everything `/etc/sysupgrade.conf` lists back over the new firmware. A `/etc`
  line restores the old `/etc/apk/world` (old `kernel=` and `base-files=` pins: every apk command
  fails), the old feed lists and `/etc/openwrt_release`, old init scripts, and the resize markers
  `/etc/rootpt-resize` and `/etc/rootfs-resize` (the root stays at the image's small size).
- Files outside the keep list and outside package config files are gone, e.g. binaries in
  `/usr/local/bin` or Docker data in `/opt/docker`.
- owut drops the default `dnsmasq` when `dnsmasq-full` is installed. If `dnsmasq-full` was only a
  dependency of a package left out of the image, the image has no DNS server.

Hence: build a default ("clean slate") image, keep only your own files, and reinstall packages
with apk after the reboot.

## Before

1. Take a VM snapshot or another full backup.
2. Packages from outside the official feeds: put the `.apk` files of packages that are in no feed
   in `/root/thirdparty/` (the router does not keep them after installing). Add a third-party feed
   with many packages as a tagged repository (`@<tag> <url>` in `customfeeds.list`, install with
   `apk add <package>@<tag>`) so it cannot replace official packages; owut ignores tagged feeds and
   reports their packages as missing, which does not stop a `--clean-slate` upgrade.
3. Save the package list and the enabled services:
   `mkdir -p /root/upgrade && cp /etc/apk/world /root/upgrade/world && ls /etc/rc.d > /root/upgrade/rc.d`
4. Remove a `/etc` line from `/etc/sysupgrade.conf` and add your own files instead. `/etc/config`
   and changed package config files are kept anyway. This lists files under `/etc` that would
   now be lost and that no package owns:
   `sysupgrade -l > /tmp/keep; find /etc \( -type f -o -type l \) | grep -vxF -f /tmp/keep | while read -r f; do apk info -q --who-owns "$f" >/dev/null 2>&1 || echo "$f"; done`
   (ignore `rc.d/`, `apk/`, `*.apk-new`, `board.json`, `urandom.seed` and the resize markers);
   `apk audit /etc` shows edited package files that are not config files. Also add directories
   with your own binaries (e.g. `/usr/local/bin`) and the `rc.d` links of your own init scripts.
5. Check `sysupgrade -l`: it must not list `/etc/apk/world`, `/etc/openwrt_release` or
   `/etc/rootpt-resize`; it must list the key of every non-official feed in `/etc/apk/keys/`
   (e.g. `openwrt-packages.pem`), `/etc/apk/repositories.d/customfeeds.list` and `/root/thirdparty/`.

## Upgrade

```sh
owut upgrade -V <release> --clean-slate --repositories-mode disable -a parted,losetup,resize2fs
```

`-a` adds the tools the resize scripts need, so the first boot grows the root again (two extra
reboots). `--repositories-mode disable` keeps owut from sending the custom feed. When the
installed packages fit the default root size, `-r <feed and files-only packages>` without
`--clean-slate` also works and leaves less to reinstall.

## After

1. Point the feed at the new release (and re-apply a download mirror in `distfeeds.list` if used):
   `sed -i "s|/<old>/|/<new>/|" /etc/apk/repositories.d/customfeeds.list`. Feeds whose URL only
   names the series (e.g. `.../25.12/...`) stay as they are within it.
2. Reinstall the saved package list without version pins and file hashes (`<package>@<tag>`
   entries stay): `apk update && apk add $(grep -vE '=|><' /root/upgrade/world)`
3. Reinstall files-only packages: `apk add --allow-untrusted /root/thirdparty/*.apk`
4. Compare services: `ls /etc/rc.d | grep -vxF -f /root/upgrade/rc.d` (newly enabled) and
   `ls /etc/rc.d | grep -vxF -f - /root/upgrade/rc.d` (no longer enabled).
5. Merge new defaults: `find /etc -name '*.apk-new'`.
6. Append own CA certificates to `/etc/ssl/certs/ca-certificates.crt` again if you had added any
   (the bundle now comes from the new `ca-bundle`).
7. Recreate what lived outside the keep list (e.g. `docker compose up -d` for containers).
8. Check: `grep DISTRIB_RELEASE /etc/openwrt_release`, `df -h /`,
   `/usr/share/fullcone/fullcone.sh status` reports `"mode":"fullcone"`.
