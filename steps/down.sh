#!/usr/bin/env bash
# Stop and remove the app containers. riptides itself is left alone.
#
# Deliberately a script rather than a one-line Makefile recipe: it needs the
# runtime that preflight detects (not a hardcoded guess), it has to pass the
# passthrough override too so containers created by act 2b are matched, and it
# verifies the result instead of trusting the exit code.
set -euo pipefail

DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$DEMO_DIR/lib/preflight.sh"
source "$DEMO_DIR/lib/demo.sh"

act "Stopping the demo app"

step "compose down, with both compose files so act 2b's containers match too"
vmrun "$COMPOSE_PT down --remove-orphans 2>&1 | tail -3"

step "Sweeping anything left behind"
# A container created under a different compose invocation, or one whose project
# labels got lost, would survive the above. Remove by name as a backstop.
vmrun "$RT rm -f demo-nginx demo-httpbin demo-redis demo-redis-cli demo-client 2>/dev/null | tail -2 || true"

step "Verifying"
left="$(vm "$RT ps -a --format '{{.Names}}' 2>/dev/null | grep -c '^demo-' || true")"
if [[ "${left:-0}" -eq 0 ]]; then
  good "no demo containers remain"
else
  bad "$left demo container(s) still present:"
  vmrun "$RT ps -a --format '{{.Names}}\t{{.Status}}' | grep '^demo-' || true"
  exit 1
fi
printf '\n'
