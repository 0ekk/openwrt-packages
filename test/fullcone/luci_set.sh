#!/bin/sh
# Runs in the lab VM: what LuCI's Save & Apply sends to rpcd (login, uci set, uci apply with
# rollback, confirm). rpcd then raises config.change and procd reloads fullcone after 1 s.
# Usage: sh -s OPTION VALUE < luci_set.sh
sid=$(ubus call session login '{"username":"root","password":""}' | jsonfilter -e '@.ubus_rpc_session')
[ -n "$sid" ] || { echo "rpcd login failed" >&2; exit 1; }
ubus call uci set "{\"ubus_rpc_session\":\"$sid\",\"config\":\"fullcone\",\"section\":\"main\",\"values\":{\"$1\":\"$2\"}}" &&
	ubus call uci apply "{\"ubus_rpc_session\":\"$sid\",\"rollback\":true,\"timeout\":30}" &&
	ubus call uci confirm "{\"ubus_rpc_session\":\"$sid\"}" &&
	sleep 3
