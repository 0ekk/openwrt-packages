# openwrt-packages

A small apk feed for stock OpenWrt (25.12 and later), built with the official SDK on GitHub
Actions and published on GitHub Pages: `https://0ekk.github.io/openwrt-packages/`.

| Packages | What |
|---|---|
| `luci-app-fullcone`, `fullcone`, `kmod-ipt-fullconenat`, `iptables-mod-fullconenat` | IPv4 UDP full cone NAT (NAT1) for firewall4: [docs/fullcone.md](docs/fullcone.md) |

Builds exist for each file in [sdk/](sdk/) (now: 25.12.5 and 25.12.6, x86/64). Kernel modules
only install on the exact kernel of that release.

## Use the feed on a router

```sh
wget -O /etc/apk/keys/openwrt-packages.pem https://0ekk.github.io/openwrt-packages/keys/openwrt-packages.pem
echo /etc/apk/keys/openwrt-packages.pem >> /etc/sysupgrade.conf
echo https://0ekk.github.io/openwrt-packages/25.12.5/x86/64/packages.adb >> /etc/apk/repositories.d/customfeeds.list
apk update
apk add luci-app-fullcone
```

Upgrade: `apk update && apk upgrade` (everything), or only these packages with
`apk add -u luci-app-fullcone fullcone iptables-mod-fullconenat kmod-ipt-fullconenat`, which
also upgrades their dependencies (e.g. `luci-base`); add `--simulate` first. Packages that were
installed from files stay pinned to that file until `apk add <name>` re-adds them by name.

Compare the downloaded key with [keys/openwrt-packages.pem](keys/openwrt-packages.pem) in this
repository. After a firmware upgrade, point the feed line at the new release.

## Add a package

1. Put an OpenWrt package directory in `package/<name>/`. `package/` is built as a feed, so
   dependencies from the OpenWrt base feed are pulled in automatically.
2. Optional QEMU test: `test/<name>/check.sh`, sourced by `test/lab.sh check`.
3. Bump `PKG_RELEASE` (or the version) on every change, otherwise `apk upgrade` ignores it.
4. Push to `main`: the `feed` workflow builds, signs and publishes.

## Add a release or target

`sdk/new.sh <release> <target>` (e.g. `sdk/new.sh 25.12.6 x86/64`) writes
`sdk/<release>-<target>.env` from the release's download directory: SDK name and sha256 from
`sha256sums`, kernel pin from the `kmods/` directory name. Commit it and push. Keep the old file
until no router uses it.

## Build and test locally

```sh
./build.sh [sdk/<release>-<target>.env]   # out/*.apk; MIRROR=https://<mirror>/openwrt to change the host
test/lab.sh up && test/lab.sh check       # root + KVM; needs qemu-system-x86_64 and pppoe-server
test/lab.sh down
ROUTER=root@<router> ./install.sh         # install out/*.apk without the feed
```

## Signing

The workflow signs `packages.adb` with the `APK_SIGN_KEY` secret (EC P-256 private key, PEM);
the public half is `keys/openwrt-packages.pem`. To rotate: make a new pair, replace the secret
and `keys/`, and install the new public key on every router. Design notes: [docs/plan/](docs/plan/).
