#!/usr/bin/env bash
# Runs inside the VM. Samples /proc/riptides/connections until a connection on
# the given port is live, optionally driving traffic while it waits.
#
#   vm-conns.sh <port|.> [generator-command]
#
# The proc file lists live sockets only, and both demo legs are short-lived
# (redis-cli reconnects every 2s; nginx keeps one upstream connection but only
# while it has work). Polling is what makes this evidence reproducible instead
# of a coin flip.
set -uo pipefail

port="${1:?port required}"
gen="${2:-}"
genpid=""

if [[ -n "$gen" ]]; then
    # nginx holds its upstream connection open, so one request is usually all it
    # takes for the connection to show up. Pace this so a slow poll does not
    # turn into dozens of handshakes.
    ( while :; do bash -c "$gen" >/dev/null 2>&1; sleep 1; done ) &
    genpid=$!
fi

filter='
  select($p == "." or (.dst_port|tostring) == $p or (.src_port|tostring) == $p)
  | {dst: "\(.dst):\(.dst_port)", tls: .tls_version, mtls: .mtls_version,
     id: .spiffe_id, peer: .peer_spiffe_id}'

found=""
for _ in $(seq 40); do
    out="$(sudo cat /proc/riptides/connections 2>/dev/null | jq -c --arg p "$port" "$filter" 2>/dev/null)"
    if [[ -n "$out" ]]; then
        printf '%s\n' "$out"
        found=1
        break
    fi
    sleep 0.25
done

[[ -n "$genpid" ]] && kill "$genpid" 2>/dev/null
wait "$genpid" 2>/dev/null

[[ -n "$found" ]] || echo "(no live connection on port $port in 10s)"
exit 0
