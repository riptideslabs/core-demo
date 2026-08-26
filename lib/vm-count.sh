#!/usr/bin/env bash
# Runs on the target. Counts how many packets on <port> carry <pattern> in their
# payload, out of every packet seen in the window, while a generator drives
# traffic.
#
#   vm-count.sh <port> <pattern> [generator] [seconds]
#
# Prefers ngrep, falls back to tcpdump. That fallback matters: ngrep is not
# packaged for Amazon Linux 2023 — not in its repos and not in EPEL9 — and this
# count is the strongest evidence act 2 has, so it cannot be Lima-only.
#
# Either way the shape is the same: capture everything, then count the pattern in
# the rendered payload. Both tools print non-printable bytes as '.', so this works
# identically on an encrypted payload — it just finds nothing, which is the point.
set -uo pipefail

port="${1:?port required}"
pattern="${2:?pattern required}"
gen="${3:-}"
secs="${4:-5}"
genpid=""

if command -v ngrep >/dev/null 2>&1; then
    tool=ngrep
elif command -v tcpdump >/dev/null 2>&1; then
    tool=tcpdump
else
    echo "neither ngrep nor tcpdump is installed — NO measurement was taken"
    echo "install: sudo dnf install -y tcpdump   (or apt-get install -y tcpdump)"
    exit 0
fi

if [[ -n "$gen" ]]; then
    # One generator run per second: at 0.25s a single capture opened ~33
    # connections, each a fresh handshake, span and console row.
    ( end=$((SECONDS + secs))
      while [ "$SECONDS" -lt "$end" ]; do bash -c "$gen" >/dev/null 2>&1; sleep 1; done ) &
    genpid=$!
fi

if [[ "$tool" == ngrep ]]; then
    # -l matters: with -q alone ngrep buffers and the output is lost when
    # timeout signals it. An empty pattern matches every packet.
    out="$(sudo timeout "$secs" ngrep -d lo -l -q -W byline '' "tcp port $port" 2>/dev/null)"
    total="$(printf '%s\n' "$out" | grep -c ' -> ' || true)"
else
    # -A prints payload as ASCII; each packet starts with a timestamped IP line.
    # 'greater 90' drops bare ACKs so the totals stay comparable to ngrep's.
    out="$(sudo timeout "$secs" tcpdump -i lo -A -l -q "tcp port $port and greater 90" 2>/dev/null)"
    total="$(printf '%s\n' "$out" | grep -cE '^[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]+ IP ' || true)"
fi

if [[ -n "$genpid" ]]; then
    kill "$genpid" 2>/dev/null
    wait "$genpid" 2>/dev/null
fi

hits="$(printf '%s\n' "$out" | grep -cF "$pattern" || true)"

printf 'packets seen: %-4s  carrying "%s": %-4s (via %s)\n' "$total" "$pattern" "$hits" "$tool"
if [[ "$hits" -gt 0 ]]; then
    printf '%s\n' "$out" | grep -F -m1 -A2 "$pattern" | sed 's/^/  | /'
fi

# Zero hits out of zero packets is not evidence of anything — it means no traffic
# crossed the wire during the window, usually because the leg is broken. Say so,
# and exit 2 so the caller can refuse to claim success on it.
if [[ "$total" -eq 0 ]]; then
    echo "NO PACKETS SEEN — nothing was measured on port $port"
    exit 2
fi
exit 0
