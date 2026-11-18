#!/usr/bin/env python3
"""Full cone check for the QEMU lab (root on the lab host, Python 3.12+ for os.setns).

Usage: check_cone.py udp|tcp 4|6 PORT
Opens sockets in both lab netns from one process, so no background helpers are needed:
1. The LAN host talks from PORT to WAN1 port 3480 (WAN side), which sees the router's mapping
   ext_ip:ext_port. TCP: the LAN host also listens on PORT.
2. Filtering, tested before anything else touches WAN2: WAN2, never contacted, sends to (UDP) or
   connects to (TCP) ext_ip:ext_port. Full cone: the LAN socket gets it.
3. Mapping: the LAN host talks from PORT again, to WAN2 port 3480. Full cone: same ext_ip:ext_port.
Exit 0 with "RESULT: <proto> Full Cone (NAT1)", 1 when not full cone, 2 on a setup error.
"""
import os
import socket
import sys

ADDRS = {  # LAN host, WAN1, WAN2 (test/lab.sh)
    "4": ("192.168.1.100", "203.0.113.1", "203.0.113.2"),
    "6": ("fd00:1::100", "2001:db8:b::1", "2001:db8:b::2"),
}
SRV_PORT = 3480  # 3478/3479 UDP belong to the lab STUN server
TIMEOUT = 3


def netns(name):
    fd = os.open(f"/run/netns/{name}", os.O_RDONLY)
    try:
        os.setns(fd, os.CLONE_NEWNET)
    finally:
        os.close(fd)


def main():
    if len(sys.argv) != 4 or sys.argv[1] not in ("udp", "tcp") or sys.argv[2] not in ADDRS:
        print(__doc__, file=sys.stderr)
        return 2
    proto, family, port = sys.argv[1], sys.argv[2], int(sys.argv[3])
    lan, wan1, wan2 = ADDRS[family]
    tcp = proto == "tcp"
    fam = socket.AF_INET if family == "4" else socket.AF_INET6

    def sock(bind, reuse=False):
        s = socket.socket(fam, socket.SOCK_STREAM if tcp else socket.SOCK_DGRAM)
        s.settimeout(TIMEOUT)
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        if reuse:
            s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
        s.bind(bind)
        return s

    own = os.open("/proc/self/ns/net", os.O_RDONLY)
    socks = []
    try:
        netns("fcl-wan")
        srv1, srv2, probe = sock((wan1, SRV_PORT)), sock((wan2, SRV_PORT)), sock((wan2, 0))
        netns("fcl-lan")
        if tcp:
            lst = sock((lan, port), reuse=True)
            c1, c2 = sock((lan, port), reuse=True), sock((lan, port), reuse=True)
            for s in (srv1, srv2, lst):
                s.listen(4)
        else:
            lst = c1 = c2 = sock((lan, port))
        socks = [srv1, srv2, probe, lst, c1, c2]
    except OSError as e:
        print(f"setup error: {e}", file=sys.stderr)
        return 2
    finally:
        os.setns(own, os.CLONE_NEWNET)
        os.close(own)

    def mapped_via(server, client):
        """The client's address as the server sees it. Accepted TCP sockets go to socks, so the
        flow (and the router's mapping) stays established."""
        if tcp:
            client.connect(server.getsockname()[:2])
            conn, peer = server.accept()
            socks.append(conn)
        else:
            client.sendto(b"x", server.getsockname()[:2])
            _, peer = server.recvfrom(64)
        return peer[:2]

    def unsolicited(ext):
        if tcp:
            probe.connect(ext)
            conn, peer = lst.accept()
            conn.close()
        else:
            probe.sendto(b"p", ext)
            _, peer = lst.recvfrom(64)
        return peer[:2]

    try:
        ext = mapped_via(srv1, c1)
    except OSError as e:
        print(f"setup error: LAN cannot reach {wan1} port {SRV_PORT}: {e}", file=sys.stderr)
        return 2
    print(f"{proto}: mapping {lan} port {port} -> {ext[0]} port {ext[1]} (seen by {wan1})")

    filtering_open = False
    try:
        peer = unsolicited(ext)
        filtering_open = peer[0] == wan2
        print(f"unsolicited {wan2} -> {ext[0]} port {ext[1]} reached the LAN socket from {peer[0]} port {peer[1]}")
    except OSError as e:
        print(f"unsolicited {wan2} -> {ext[0]} port {ext[1]} did not reach the LAN: {e}")

    try:
        ext2 = mapped_via(srv2, c2)
        print(f"{proto}: mapping {lan} port {port} -> {ext2[0]} port {ext2[1]} (seen by {wan2})")
    except OSError as e:
        print(f"setup error: LAN cannot reach {wan2} port {SRV_PORT}: {e}", file=sys.stderr)
        return 2

    for s in socks:
        s.close()
    if filtering_open and ext2 == ext:
        print(f"RESULT: {proto.upper()} Full Cone (NAT1)")
        return 0
    print(f"RESULT: not {proto.upper()} full cone (filtering {'open' if filtering_open else 'closed'}, "
          f"mapping {'kept' if ext2 == ext else 'changed'})")
    return 1


if __name__ == "__main__":
    sys.exit(main())
