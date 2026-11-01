#!/usr/bin/env python3
"""RFC 5780 NAT behavior test, run from a LAN host.

Usage: python3 check_nat.py [host[:port]]   (default stun.miwifi.com:3478)
Exit code 0 means Full Cone (endpoint-independent mapping and filtering).
A host firewall that drops unsolicited UDP makes filtering look stricter than it is.
"""
import os
import socket
import struct
import sys

COOKIE = 0x2112A442


def request(change=0):
    tid = os.urandom(12)
    attrs = struct.pack("!HHI", 0x0003, 4, change) if change else b""
    return tid, struct.pack("!HHI", 0x0001, len(attrs), COOKIE) + tid + attrs


def address(v, xor):
    port = struct.unpack("!H", v[2:4])[0]
    ip = v[4:8]
    if xor:
        port ^= COOKIE >> 16
        ip = bytes(a ^ b for a, b in zip(ip, struct.pack("!I", COOKIE)))
    return socket.inet_ntoa(ip), port


def parse(msg):
    out, i = {}, 20
    while i + 4 <= len(msg):
        t, n = struct.unpack("!HH", msg[i:i + 4])
        v = msg[i + 4:i + 4 + n]
        if t == 0x0020:
            out["mapped"] = address(v, True)
        elif t == 0x0001:
            out.setdefault("mapped", address(v, False))
        elif t in (0x802C, 0x0005):
            out["other"] = address(v, False)
        i += 4 + n + (-n % 4)
    return out


def udp_socket():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.bind(("0.0.0.0", 0))
    s.settimeout(1.0)
    return s


def test(s, dst, change=0, tries=3):
    for _ in range(tries):
        tid, msg = request(change)
        s.sendto(msg, dst)
        try:
            while True:
                data, src = s.recvfrom(2048)
                if data[8:20] == tid:
                    return src, parse(data)
        except socket.timeout:
            pass
    return None


def main():
    host, _, port = (sys.argv[1] if len(sys.argv) > 1 else "stun.miwifi.com:3478").partition(":")
    server = (socket.gethostbyname(host), int(port or 3478))

    # Filtering first, on a socket that has only talked to the primary address:
    # sending to the alternate address first would open the NAT for its replies.
    f = udp_socket()
    r = test(f, server)
    if not r or "mapped" not in r[1]:
        sys.exit("no response from the STUN server")
    mapped, other = r[1]["mapped"], r[1].get("other")
    print(f"local port {f.getsockname()[1]} -> mapped {mapped[0]}:{mapped[1]}")
    if not other:
        sys.exit("server has no OTHER-ADDRESS, pick an RFC 5780 server")
    r = test(f, server, change=0x06)
    if r:
        if r[0] != other:
            sys.exit(f"CHANGE-REQUEST answered from {r[0][0]}:{r[0][1]}, server cannot test filtering")
        filtering = "endpoint-independent"
    else:
        r = test(f, server, change=0x02)
        if r and r[0] != (server[0], other[1]):
            sys.exit(f"CHANGE-REQUEST answered from {r[0][0]}:{r[0][1]}, server cannot test filtering")
        filtering = "address-dependent" if r else "address-and-port-dependent"

    m = udp_socket()
    m1, m2, m3 = (test(m, dst) for dst in (server, (other[0], server[1]), other))
    m1, m2, m3 = (x[1].get("mapped") if x else None for x in (m1, m2, m3))
    if m1 is None or m2 is None:
        mapping = "unknown (no answer)"
    elif m2 != m1 or (m3 and m3 != m1):
        mapping = "endpoint-dependent (symmetric)"
    else:
        mapping = "endpoint-independent"

    print(f"mapping:   {mapping}\nfiltering: {filtering}")
    full = mapping == filtering == "endpoint-independent"
    print("RESULT:", "Full Cone (NAT1)" if full else "not Full Cone")
    sys.exit(0 if full else 1)


if __name__ == "__main__":
    main()
