#!/bin/sh
# Install a local build (out/*.apk) on a router without the feed, e.g. to try a change.
# Simulates first and never forces past the kernel pin: a resolution error means the SDK does
# not match the router, rebuild. ROUTER defaults to OpenWrt's root@192.168.1.1.
set -eu

ROUTER=${ROUTER:-root@192.168.1.1}
cd "$(dirname "$0")/out"
tar -cf - ./*.apk | ssh -T -o BatchMode=yes "$ROUTER" 'rm -rf /tmp/pkgs && mkdir /tmp/pkgs && tar -xf - -C /tmp/pkgs'
ssh -T -o BatchMode=yes "$ROUTER" 'cd /tmp/pkgs &&
	apk add --simulate --allow-untrusted ./*.apk &&
	apk add --allow-untrusted ./*.apk'
