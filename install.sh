#!/bin/sh
# Copy out/*.apk to the router and install them. Simulates first and never forces past
# the kernel pin: a resolution error means the SDK does not match the router, rebuild.
set -eu

ROUTER=${ROUTER:-root@192.168.1.1}
cd "$(dirname "$0")/out"
tar -cf - ./*.apk | ssh -T -o BatchMode=yes "$ROUTER" 'rm -rf /tmp/fullcone && mkdir /tmp/fullcone && tar -xf - -C /tmp/fullcone'
ssh -T -o BatchMode=yes "$ROUTER" 'cd /tmp/fullcone &&
	apk add --simulate --allow-untrusted ./*.apk &&
	apk add --allow-untrusted ./*.apk &&
	/usr/share/fullcone/fullcone.sh status'
