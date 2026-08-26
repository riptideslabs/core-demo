#!/bin/sh
# The Redis client's workload: set a key, read it back, wait, repeat.
#
# It reconnects on every iteration, so a policy change shows up in
# `docker logs demo-redis-cli` within one loop instead of waiting for a
# long-lived connection to drop.
#
# Lives in a file rather than compose's `command:` so that the $(...) here is
# plain shell, with no compose $$-escaping to get wrong.

# Seconds between iterations. Each one opens two connections (a set and a get),
# so this is the demo's idle connection rate: 2/INTERVAL per second.
INTERVAL="${INTERVAL:-4}"

# Empty on the plaintext leg; set to "--tls --cacert …" by
# compose.passthrough.yaml when Redis is doing its own TLS.
REDIS_TLS_ARGS="${REDIS_TLS_ARGS:-}"

while true; do
    # The changing value goes in on stdin, never in argv: a workload's identity
    # is derived partly from its command line, so a timestamp there minted a
    # brand new identity every iteration and filled the console with thousands
    # of one-shot workloads. Constant argv collapses them all to one.
    #
    # REDIS_TLS_ARGS is empty on the plaintext leg and carries --tls --cacert
    # when compose.passthrough.yaml is layered on. Unquoted on purpose: it has
    # to split into separate arguments.
    # Check the reply, not the exit status: redis-cli reading commands from stdin
    # exits 0 even when the connection was reset, and prints the error as output.
    # SET replies exactly "OK", so that is the success condition.
    # shellcheck disable=SC2086
    out=$(printf 'set demo:ts %s\n' "$(date +%s)" |
          redis-cli $REDIS_TLS_ARGS -h 127.0.0.1 -p 6379 2>&1)
    if [ "$out" = "OK" ]; then
        # shellcheck disable=SC2086
        echo "$(date +%T) redis OK   set=$out get=$(printf 'get demo:ts\n' |
             redis-cli $REDIS_TLS_ARGS -h 127.0.0.1 -p 6379 2>&1)"
    else
        echo "$(date +%T) redis FAIL $out"
    fi
    sleep "$INTERVAL"
done
