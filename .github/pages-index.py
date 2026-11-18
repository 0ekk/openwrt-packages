#!/usr/bin/env python3
"""Write an "Index of" page into every directory of the Pages site, then check its links.

Usage: pages-index.py SITE BASE_URL COMMIT
BASE_URL is the published root (https://<owner>.github.io/<repo>/). A directory holding a
packages.adb is a feed (layout: .github/feed-site.sh): <release>/packages/<arch>/<name>/ or
<release>/targets/<target>/. Feed pages show their repository line; the root page shows the
install commands, every feed line of a release and target. Exits 1 if a generated link points to nothing, so the deploy stops.
"""
import datetime
import html
import json
import os
import re
import sys
from urllib.parse import quote, unquote, urlsplit

CSS = """
:root { color-scheme: light dark; --bg: #fff; --fg: #222; --muted: #666; --line: #ddd;
  --zebra: #f5f7f9; --link: #0b6bcb; --code: #f2f4f6; }
@media (prefers-color-scheme: dark) { :root { --bg: #16181b; --fg: #e4e6e8; --muted: #9aa0a6;
  --line: #33373c; --zebra: #1d2024; --link: #6cb4ff; --code: #202328; } }
body { margin: 0 auto; max-width: 60rem; padding: 1rem; background: var(--bg); color: var(--fg);
  font: 15px/1.5 system-ui, sans-serif; }
h1 { font-size: 1.3rem; font-weight: 600; overflow-wrap: anywhere; }
h2 { font-size: 1.1rem; margin-top: 1.5rem; }
h3 { font-size: 1rem; margin-bottom: .3rem; }
a { color: var(--link); text-decoration: none; }
a:hover { text-decoration: underline; }
.box { overflow-x: auto; }
table { border-collapse: collapse; width: 100%; }
th, td { text-align: left; padding: .35rem .6rem; border-bottom: 1px solid var(--line);
  white-space: nowrap; }
.s { text-align: right; font-family: ui-monospace, monospace; }
tr:nth-child(even) td { background: var(--zebra); }
pre { background: var(--code); padding: .7rem .9rem; overflow-x: auto; border-radius: 4px;
  font: 13px/1.45 ui-monospace, monospace; }
footer { margin-top: 1.5rem; color: var(--muted); font-size: .85rem; }
"""
REPO_LIST = "/etc/apk/repositories.d/customfeeds.list"


def human(n):
    if n < 1024:
        return f"{n} B"
    for unit in ("KiB", "MiB", "GiB"):
        n /= 1024
        if n < 1024 or unit == "GiB":
            return f"{n:.1f} {unit}"


def pre(*lines):
    return "<pre>" + html.escape("\n".join(lines)) + "</pre>"


def kind(feed):
    """'packages' or 'targets' for a feed path such as 25.12.5/targets/x86/64."""
    return feed.split("/")[1]


def arch(site, feed):
    with open(os.path.join(site, feed, "index.json"), encoding="utf-8") as f:
        return json.load(f)["architecture"]


def echo(base, feed):
    return f"echo {base}{feed}/packages.adb >> {REPO_LIST}"


def install_blocks(site, base, feeds):
    """(heading, lines) per target: the feed lines of its release and arch (luci, packages), its
    targets feed line, then apk update. Arch feeds no target refers to get a block of their own."""
    blocks, used = [], set()
    for t in (f for f in feeds if kind(f) == "targets"):
        rel, target = t.split("/targets/", 1)
        a = arch(site, t)
        own = [f for f in feeds if f.startswith(f"{rel}/packages/{a}/")]
        used.update(own)
        blocks.append((f"{rel} · {target} ({a})", [echo(base, f) for f in own + [t]] + ["apk update"]))
    rest = [f for f in feeds if kind(f) == "packages" and f not in used]
    for rel_arch in dict.fromkeys(f.rsplit("/", 1)[0] for f in rest):
        rel, _, a = rel_arch.split("/", 2)
        lines = [echo(base, f) for f in rest if f.startswith(rel_arch + "/")]
        blocks.append((f"{rel} · {a}", lines + ["apk update"]))
    return blocks


def page(site, rel, base, root_name, footer, feeds, keys):
    path = os.path.join(site, rel)
    parts = [p for p in rel.split("/") if p]
    up = len(parts)
    crumbs = [f'<a href="{"../" * up or "./"}">{html.escape(root_name)}</a>']
    crumbs += [f'<a href="{"../" * (up - i - 1) or "./"}">{html.escape(p)}</a>' for i, p in enumerate(parts)]
    title = "Index of /" + "/".join([root_name] + parts) + "/"

    body = [f"<h1>Index of /{'/'.join(crumbs)}/</h1>"]
    if not parts:
        body.append("<p>A small signed apk feed for stock OpenWrt, built with the official SDK. "
                    f'Package docs: <a href="{html.escape(footer["repo"])}#readme">README</a>.</p>')
        if keys:
            body.append("<h2>Use the feed</h2><p>Add the signing key once:</p>")
            body.append(pre(f"wget -O /etc/apk/keys/{keys[0]} {base}keys/{keys[0]}",
                            f"echo /etc/apk/keys/{keys[0]} >> /etc/sysupgrade.conf"))
        body.append("<p>Then add the feeds of your release and target (packages and LuCI apps "
                    "for the architecture, kernel modules for the target), and update:</p>")
        for heading, lines in install_blocks(site, base, feeds):
            body.append(f"<h3>{html.escape(heading)}</h3>")
            body.append(pre(*lines))
        body.append("<h2>Files</h2>")
    elif rel in feeds:
        body.append(pre(echo(base, rel)))
        body.append("<p>A router needs every feed of its release: packages and LuCI apps for its "
                    "architecture, kernel modules for its target. See the "
                    f'<a href="{"../" * up}">feed root</a>.</p>')

    rows = [] if not parts else ['<tr><td><a href="../">../</a></td><td class="s">-</td></tr>']
    entries = sorted(os.scandir(path), key=lambda e: (not e.is_dir(), e.name))
    for e in entries:
        if e.name == "index.html":
            continue
        if e.is_dir():
            rows.append(f'<tr><td><a href="{quote(e.name)}/">{html.escape(e.name)}/</a></td><td class="s">-</td></tr>')
        else:
            rows.append(f'<tr><td><a href="{quote(e.name)}">{html.escape(e.name)}</a></td>'
                        f'<td class="s">{human(e.stat().st_size)}</td></tr>')
    body.append('<div class="box"><table><tr><th>Name</th><th class="s">Size</th></tr>'
                + "".join(rows) + "</table></div>")
    body.append(f'<footer>Built {footer["time"]} from <a href="{html.escape(footer["repo"])}/commit/'
                f'{html.escape(footer["commit"])}">{html.escape(footer["commit"][:7])}</a></footer>')

    with open(os.path.join(path, "index.html"), "w", encoding="utf-8") as out:
        out.write('<!doctype html>\n<html lang="en"><head><meta charset="utf-8">'
                  '<meta name="viewport" content="width=device-width, initial-scale=1">'
                  f"<title>{html.escape(title)}</title><style>{CSS}</style></head>"
                  f"<body>{''.join(body)}</body></html>\n")


def broken_links(site):
    """Relative hrefs in the generated pages that point to nothing under SITE."""
    site = os.path.realpath(site)
    bad = []
    for d, _, files in os.walk(site):
        if "index.html" not in files:
            bad.append(os.path.relpath(d, site) + "/ (no index.html)")
            continue
        text = open(os.path.join(d, "index.html"), encoding="utf-8").read()
        for href in re.findall(r'href="([^"]+)"', text):
            if re.match(r"[a-z]+:", href):
                continue
            target = os.path.realpath(os.path.join(d, unquote(html.unescape(href))))
            if not (target == site or target.startswith(site + os.sep)) or not os.path.exists(target):
                bad.append(f"{os.path.relpath(d, site)}/index.html: {href}")
    return bad


def main():
    if len(sys.argv) != 4:
        print(__doc__, file=sys.stderr)
        return 2
    site, base, commit = sys.argv[1], sys.argv[2], sys.argv[3]
    if not base.endswith("/"):
        base += "/"
    u = urlsplit(base)
    owner, repo = u.hostname.split(".")[0], u.path.strip("/")
    footer = {"time": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d %H:%M UTC"),
              "repo": f"https://github.com/{owner}/{repo}", "commit": commit}
    feeds = sorted(os.path.relpath(d, site) for d, _, files in os.walk(site) if "packages.adb" in files)
    keys_dir = os.path.join(site, "keys")
    keys = sorted(k for k in os.listdir(keys_dir) if k.endswith(".pem")) if os.path.isdir(keys_dir) else []
    for d, dirs, _ in os.walk(site):
        dirs.sort()
        rel = os.path.relpath(d, site)
        page(site, "" if rel == "." else rel, base, repo, footer, feeds, keys)
    bad = broken_links(site)
    for b in bad:
        print(f"broken link: {b}", file=sys.stderr)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
