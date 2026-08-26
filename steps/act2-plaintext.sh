#!/usr/bin/env bash
# Put the Redis leg back to plaintext after act 2b, so act 2 works again.
set -euo pipefail

DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$DEMO_DIR/lib/preflight.sh"
source "$DEMO_DIR/lib/demo.sh"

act "Back to the plaintext Redis leg"

step "Dropping the passthrough policy"
for f in "$DEMO_DIR"/policies/04-passthrough/1*.yaml; do delete "$f"; done

step "Recreating redis and redis-cli without the TLS override"
# compose.yaml alone: no --tls-port, no REDIS_TLS_ARGS, plaintext 6379 back.
vmrun "$COMPOSE up -d --force-recreate redis redis-cli 2>&1 | tail -1"
settle 8
vmrun "$RT logs --tail 2 demo-redis-cli"

step "Confirming the wire is readable again"
say "If this shows hits, act 2's before-capture is trustworthy again:"
plaintext 6379 "demo:ts"

good "plaintext leg restored — 'make act2' is ready"
printf '\n'
