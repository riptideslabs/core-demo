#!/usr/bin/env bash
# Runs inside the VM. Taps loopback for a few payload-carrying packets while an
# optional generator drives traffic.
#
#   vm-sniff.sh <port> [generator-command]
#
# Kept as a file so the background-tap-then-generate dance happens entirely in
# the VM, with no quoting to get wrong across the host boundary.
set -uo pipefail

port="${1:?port required}"
gen="${2:-}"

if ! command -v tcpdump >/dev/null 2>&1; then
    echo "tcpdump is not installed in the VM — capture skipped"
    echo "install: sudo apt-get install -y tcpdump"
    exit 0
fi

sudo timeout 8 tcpdump -i lo -A -c 6 -q "tcp port $port and greater 90" 2>/dev/null &
tap=$!

sleep 1
if [[ -n "$gen" ]]; then
  bash -c "$gen" >/dev/null 2>&1 || true
fi

wait "$tap" 2>/dev/null || true
