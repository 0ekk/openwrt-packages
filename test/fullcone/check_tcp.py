#!/usr/bin/env python3
"""TCP full cone check for the QEMU lab (root on the lab host, Python 3.12+ for os.setns).

Opens sockets in both lab netns from one process, so no background helpers are needed:
1. LAN 192.168.1.100 listens on PORT and connects from PORT to 203.0.113.1:3479 (WAN side).
   The WAN side sees the router's mapping ext_ip:ext_port.
2. Filtering, tested before anything else touches 203.0.113.2: 203.0.113.2, never contacted,
   connects to ext_ip:ext_port. Full cone: the LAN listener accepts it.
3. Mapping: the LAN connects from PORT again, to 203.0.113.2:3479. Full cone: same ext_ip:ext_port.
Exit 0 with "RESULT: TCP Full Cone (NAT1)", 1 when not full cone, 2 on a setup error.
"""
import os
import socket
import sys

LAN, WAN1, WAN2, SRV_PORT = "192.168.1.100", "203.0.113.1", "203.0.113.2", 3479
PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 40400
TIMEOUT = 3


def netns(name):
    fd = os.open(f"/run/netns/{name}", os.O_RDONLY)
    try:
        os.setns(fd, os.CLONE_NEWNET)
    finally:
        os.close(fd)


def tcp(bind, reuse=False):
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(TIMEOUT)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    if reuse:
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
    s.bind(bind)
    return s


def mapped_via(server, client, keep):
    """Connect client to server and return the client's address as the server sees it.
    The accepted socket goes to keep, so the flow (and the router's mapping) stays established."""
    client.connect(server.getsockname())
    conn, peer = server.accept()
    keep.append(conn)
    return peer


def main():
    own = os.open("/proc/self/ns/net", os.O_RDONLY)
    socks = []
    try:
        netns("fcl-wan")
        srv1, srv2 = tcp((WAN1, SRV_PORT)), tcp((WAN2, SRV_PORT))
        srv1.listen(4)
        srv2.listen(4)
        probe = tcp((WAN2, 0))
        netns("fcl-lan")
        lst = tcp((LAN, PORT), reuse=True)
        lst.listen(4)
        c1, c2 = tcp((LAN, PORT), reuse=True), tcp((LAN, PORT), reuse=True)
        socks = [srv1, srv2, probe, lst, c1, c2]
    except OSError as e:
        print(f"setup error: {e}", file=sys.stderr)
        return 2
    finally:
        os.setns(own, os.CLONE_NEWNET)
        os.close(own)

    try:
        ext = mapped_via(srv1, c1, socks)
    except OSError as e:
        print(f"setup error: LAN cannot reach {WAN1}:{SRV_PORT}: {e}", file=sys.stderr)
        return 2
    print(f"mapping {LAN}:{PORT} -> {ext[0]}:{ext[1]} (seen by {WAN1})")

    filtering_open = False
    try:
        probe.connect(ext)
        conn, peer = lst.accept()
        filtering_open = peer[0] == WAN2
        conn.close()
        print(f"unsolicited {WAN2} -> {ext[0]}:{ext[1]} reached the LAN listener from {peer[0]}:{peer[1]}")
    except OSError as e:
        print(f"unsolicited {WAN2} -> {ext[0]}:{ext[1]} did not reach the LAN: {e}")

    try:
        ext2 = mapped_via(srv2, c2, socks)
        print(f"mapping {LAN}:{PORT} -> {ext2[0]}:{ext2[1]} (seen by {WAN2})")
    except OSError as e:
        print(f"setup error: LAN cannot reach {WAN2}:{SRV_PORT}: {e}", file=sys.stderr)
        return 2

    for s in socks:
        s.close()
    if filtering_open and ext2 == ext:
        print("RESULT: TCP Full Cone (NAT1)")
        return 0
    print(f"RESULT: not TCP full cone (filtering {'open' if filtering_open else 'closed'}, "
          f"mapping {'kept' if ext2 == ext else 'changed'})")
    return 1


if __name__ == "__main__":
    sys.exit(main())
