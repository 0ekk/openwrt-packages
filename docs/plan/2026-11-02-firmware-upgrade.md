# Firmware upgrades for routers using the feed

## Rationale

With 25.12.6 released, `owut check` on a 25.12.5 router using the feed stopped with a 404 for
the feed's `index.json` and listed seven packages missing in the new release: the four feed
packages and three packages installed from `.apk` files that are in no feed. The router also
keeps all of `/etc` across sysupgrades and has its root partition grown by the expand-root
uci-defaults scripts. The feed side is fixed in [2026-11-01-feed.md](2026-11-01-feed.md); this
entry covers the upgrade procedure itself, [docs/firmware-upgrade.md](../firmware-upgrade.md).

## Decisions

| Topic | Decision | Why |
|---|---|---|
| Image | `owut upgrade --clean-slate --repositories-mode disable -a parted,losetup,resize2fs`, then reinstall the saved `/etc/apk/world` with apk | The attended sysupgrade server rejects custom feeds; the router's full package set exceeds the default root size, and a 1024 MB root exceeded the server's 600 s job limit |
| Keep list | List own files explicitly instead of `/etc` | Restoring `/etc` puts back the old world pins, feed lists, release files, init scripts and resize markers (rehearsal A) |
| Files-only packages | Keep their `.apk` files in `/root/thirdparty/` and reinstall with `--allow-untrusted` | They are in no feed and cannot be part of the image; `/root` is kept |
| Third-party feeds | Packages that are in another signed feed come from that feed as a tagged repository (`@<tag> <url>`, `apk add <package>@<tag>`), with its key in the keep list; only packages in no feed stay in `/root/thirdparty/`; noarch upstream release files can go into this feed instead (`prebuilt.list`, see [2026-11-01-feed.md](2026-11-01-feed.md)) | An untagged third-party feed takes part in `apk upgrade` and can replace official packages with its own builds of the same name; a tag limits it to the packages asked for by name |
| Feed URL | Rewrite the release in `customfeeds.list` after the upgrade | owut only rewrites the URL inside its build request; the device file comes back from the backup |
| Post-upgrade automation | None; manual steps in the runbook | An owut `-I` first-boot script runs from uci-defaults before the network is up, while every reinstall step needs the network |
| Lab disk | `test/lab.sh up` grows the disk image to 2 GB (sparse) and the root partition and filesystem with it (offline: `sfdisk`, `resize2fs` on a loop device) | The image's ~100 MB root cannot hold `luci-app-openclash` and its dependencies (`No space left on device`); a sysupgrade writes the image's small partition table back (rehearsal A), so upgrade rehearsals still exercise the resize scripts |

## Impact

- An upgrade takes the image build (about 2 min), three boots for the resize, and the apk
  reinstall; services from reinstalled packages run only after that step.
- Anything outside the explicit keep list and package config files is lost; the runbook's
  `find`/`apk audit` checks find candidates, the user decides.
- Docker images and containers under `/opt/docker` are not kept; compose files and volumes
  under `/root` are.
- `test/lab.sh` images are now 2 GB sparse files with a 2 GB root from the first boot.

## Verification (2026-11-01, QEMU, 25.12.5 to 25.12.6)

Setup in the lab VM like the router: root grown to 2 GB by the router's resize scripts, the
router's `sysupgrade.conf` (with `/etc`), feed packages from the feed, three stand-in packages
with the same names, versions and dependencies installed from files, own binary in
`/usr/local/bin` with an enabled init script.

- `owut check`: the feed packages resolve in 25.12.6 (`index.json`), only the three files-only
  packages are missing.
- `owut download` with the feed in append mode: `Repository not allowed: <feed>` (HTTP 400).
- Rehearsal A (keep list unchanged, `--repositories-mode disable -r` the seven packages): kernel
  6.12.112 boots, but `/etc/openwrt_release` says 25.12.5, the root is back to 104 MB with the
  resize markers present, world keeps `kernel=6.12.94…` and `base-files=1711…` (apk: "breaks:
  world[...]" for every operation), feeds point at 25.12.5, the `/usr/local/bin` binary is gone.
  The image also had no DNS server: `dnsmasq-full` was only a dependency of a removed package
  and owut had dropped `dnsmasq` (dnsmasq crash loop "jail: failed to load dependencies").
- Rehearsal B (explicit keep list, same owut options): 25.12.6, root grown back to 2 GB
  automatically, new world pins, dnsmasq and the kept binary running; after the runbook steps
  the four feed packages installed from the 25.12.6 feed, the stand-ins from `/root/thirdparty`,
  `rc.d` identical to before, `test/fullcone/check.sh` 5/5, and after a reboot the module
  loaded at boot with `mode fullcone`, dmesg clean.
- Router package set on the build server (owut blob from the router, no install): default root
  size failed with `Selected packages exceed device storage` (474 MB uncompressed);
  `rootfs_size_mb: 1024` failed with `Task exceeded maximum timeout value (600 seconds)`.
- Rehearsal C (runbook as written, `--clean-slate`): image built in 100 s, root grown
  automatically, reinstall from the saved world and `/root/thirdparty` gave a world equal to
  the old one except the release pins, `rc.d` identical, `dnsmasq-full` back and running,
  `test/fullcone/check.sh` 5/5 and `mode fullcone` after a reboot.

## Verification: third-party feed (2026-11-02, QEMU 25.12.5)

- fantastic-packages 25.12 (source of `luci-app-netdata` and `netdata-ssl`): its key from the
  feed site equals the copy in its GitHub repository and verifies both indexes; it serves
  `index.json`.
- Start like a router: both packages installed from files (hash-pinned world entries). After
  adding the key and the two feeds as `@fantastic`: `apk add go-stun` (only in that feed) fails
  with `masked in: @fantastic`; `apk add luci-app-netdata@fantastic netdata-ssl@fantastic`
  replaced the file installs with the same versions, world entries became `<name>@fantastic`;
  `apk upgrade --simulate` listed 32 upgrades, none from that feed; netdata (enabled in uci)
  answers on port 19999 with version v1.33.1.
- `owut check -V 25.12.6`: the tagged feed is not listed, its two packages are reported
  `missing to-version`.
