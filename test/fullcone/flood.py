#!/usr/bin/env python3
"""Inbound flood against a live mapping in the QEMU lab (root on the lab host, Python 3.12+).

Usage: flood.py 4|6 COUNT PPS
The LAN host opens a UDP mapping from port 40900 (assured by a reply), then WAN2 sends COUNT
datagrams at PPS from distinct source ports (WAN1 after 64512) to the mapped port: each one is a
new conntrack DNATed onto the same mapping. Prints "flooded port P: N new flows in Ts".
"""
import os
import socket
import struct
import sys
import time

ADDRS = {  # LAN host, WAN1, WAN2 (test/lab.sh)
    "4": ("192.168.1.100", "203.0.113.1", "203.0.113.2"),
    "6": ("fd00:1::100", "2001:db8:b::1", "2001:db8:b::2"),
}
LPORT, SRV_PORT = 40900, 3481  # 3478-3480 belong to the STUN server and check_cone.py


def netns(name):
    fd = os.open(f"/run/netns/{name}", os.O_RDONLY)
    try:
        os.setns(fd, os.CLONE_NEWNET)
    finally:
        os.close(fd)


def main():
    if len(sys.argv) != 4 or sys.argv[1] not in ADDRS:
        print(__doc__, file=sys.stderr)
        return 2
    family, count, pps = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
    lan, wan1, wan2 = ADDRS[family]
    fam = socket.AF_INET if family == "4" else socket.AF_INET6

    own = os.open("/proc/self/ns/net", os.O_RDONLY)
    try:
        netns("fcl-wan")
        srv = socket.socket(fam, socket.SOCK_DGRAM)
        srv.bind((wan1, SRV_PORT))
        raws = []
        for src in (wan2, wan1):
            r = socket.socket(fam, socket.SOCK_RAW, socket.IPPROTO_UDP)
            if fam == socket.AF_INET6:  # UDP over IPv6 needs a checksum; the kernel fills it in
                r.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_CHECKSUM, 6)
            r.bind((src, 0))
            raws.append(r)
        netns("fcl-lan")
        cli = socket.socket(fam, socket.SOCK_DGRAM)
        cli.bind((lan, LPORT))
    finally:
        os.setns(own, os.CLONE_NEWNET)
        os.close(own)

    srv.settimeout(3)
    cli.sendto(b"m", (wan1, SRV_PORT))
    _, peer = srv.recvfrom(64)
    srv.sendto(b"r", peer)  # a reply makes the mapping's own conntrack assured
    ext, port = peer[0], peer[1]

    t0 = time.monotonic()
    sent = 0
    for r in raws:
        for sport in range(1024, 65536):
            if sent == count:
                break
            if sent % 2000 == 0:  # keep the mapping's flow alive
                cli.sendto(b"k", (wan1, SRV_PORT))
            r.sendto(struct.pack("!HHHH", sport, port, 9, 0) + b"x", (ext, 0))
            sent += 1
            if sent % 50 == 0:
                time.sleep(max(0, t0 + sent / pps - time.monotonic()))
    print(f"flooded port {port}: {sent} new flows in {time.monotonic() - t0:.2f}s")
    return 0


if __name__ == "__main__":
    sys.exit(main())
