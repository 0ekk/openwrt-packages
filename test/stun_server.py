#!/usr/bin/env python3
"""Minimal RFC 5780 STUN server for the lab: two IPs x two ports, honors CHANGE-REQUEST.

Usage: stun_server.py IP_A IP_B [PORT_A PORT_B]   (ports default to 3478 3479)
"""
import selectors
import socket
import struct
import sys

COOKIE = 0x2112A442


def addr(ip, port, xor=False):
    raw = socket.inet_aton(ip)
    if xor:
        port ^= COOKIE >> 16
        raw = bytes(a ^ b for a, b in zip(raw, struct.pack("!I", COOKIE)))
    return struct.pack("!BBH", 0, 1, port) + raw


def attr(t, v):
    return struct.pack("!HH", t, len(v)) + v


def main():
    ips = sys.argv[1:3]
    ports = [int(p) for p in sys.argv[3:5]] or [3478, 3479]
    socks = {}
    sel = selectors.DefaultSelector()
    for ip in ips:
        for port in ports:
            s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            s.bind((ip, port))
            socks[(ip, port)] = s
            sel.register(s, selectors.EVENT_READ)

    while True:
        for key, _ in sel.select():
            s = key.fileobj
            data, src = s.recvfrom(2048)
            if len(data) < 20 or struct.unpack("!H", data[:2])[0] != 0x0001:
                continue
            change, i = 0, 20
            while i + 4 <= len(data):
                t, n = struct.unpack("!HH", data[i:i + 4])
                if t == 0x0003 and n == 4:
                    change = struct.unpack("!I", data[i + 4:i + 8])[0]
                i += 4 + n + (-n % 4)
            ip, port = s.getsockname()
            other = (ips[1 - ips.index(ip)], ports[1 - ports.index(port)])
            out = socks[(other[0] if change & 4 else ip, other[1] if change & 2 else port)]
            body = attr(0x0020, addr(*src, xor=True)) + attr(0x0001, addr(*src)) + attr(0x802C, addr(*other))
            out.sendto(struct.pack("!HHI", 0x0101, len(body), COOKIE) + data[8:20] + body, src)


if __name__ == "__main__":
    main()
