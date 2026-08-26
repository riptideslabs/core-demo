#!/usr/bin/env bash
# Preflight both sides, then start the app in the VM. No policy is applied here —
# act 1 depends on there being none.
set -euo pipefail

DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$DEMO_DIR/lib/preflight.sh"
source "$DEMO_DIR/lib/demo.sh"

act "Starting the demo app"

step "Pulling and starting five unmodified upstream containers"
vmrun "$COMPOSE up -d --pull missing"

step "Waiting for both legs to answer"
ready=""
for _ in $(seq 30); do
  if vm "curl -fsS -m 2 -o /dev/null http://127.0.0.1:8000/get \
         && $RT logs --tail 5 demo-redis-cli 2>&1 | grep -q 'redis OK'" 2>/dev/null; then
    ready=1
    break
  fi
  sleep 1
done

if [[ -n "$ready" ]]; then
  good "HTTP leg (nginx :8000 -> httpbin :8080) and RESP leg (redis-cli -> redis :6379) are live"
else
  warn "one of the legs did not come up — look at: make shell, then $COMPOSE logs"
fi

vmrun "$COMPOSE ps"

step "Both legs are plaintext right now, and no riptides policy exists yet"
note "Next: make act1"
printf '\n'
