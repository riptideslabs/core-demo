#!/usr/bin/env bash
# Act 1 — augmentation: where identity comes from, before any policy exists.
set -euo pipefail

DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$DEMO_DIR/lib/preflight.sh"
source "$DEMO_DIR/lib/demo.sh"

act "Act 1 — augmentation: identity out of a running process"

# This act's whole point is that nothing has been configured yet, so it cannot
# inherit policy from an earlier run.
step "Starting from nothing"
clear_policy 03-inject 04-passthrough 02-mtls
settle 6

step "Five upstream containers, none of which knows riptides exists"
vmrun "$COMPOSE ps"
say "No sidecar was injected. No image was rebuilt. No env var was added."
pause

step "Both legs work, in plaintext"
vmrun "curl -s -o /dev/null -w 'nginx :8000 -> httpbin :8080  HTTP %{http_code}\n' http://127.0.0.1:8000/get"
vmrun "$RT logs --tail 2 demo-redis-cli"
pause

step "What the daemon knows about the nginx worker, right now"
NGINX_PID="$(vm "pgrep -f 'nginx: worker' | head -1" 2>/dev/null || true)"
if [[ -z "$NGINX_PID" ]]; then
  bad "no nginx worker found in the VM — is the app running? (make up)"
  exit 1
fi
say "pid $NGINX_PID, discovered from the VM's process table"
vmrun "sudo riptides daemon augment $NGINX_PID"
pause

step "Those labels are the whole input to identity"
say "Selectors in the next two acts match exactly this data. The ones that matter here:"
vmrun "sudo riptides daemon augment $NGINX_PID | grep -E '^(process:name|process:binary:path|process:uid|process:gid)=' || true"

if vm "sudo riptides daemon augment $NGINX_PID | grep -q '^docker:'" 2>/dev/null; then
  say "…and the container facts, from the docker collector:"
  vmrun "sudo riptides daemon augment $NGINX_PID | grep '^docker:' || true"
else
  note "No docker:* labels here. The collector is enabled (that is the default, and"
  note "this node has no config.yaml overriding it) — but these containers run under"
  note "containerd/nerdctl, and the collector talks to the Docker API, which knows"
  note "nothing about them. There is no containerd collector; the container only"
  note "shows up indirectly, in the systemd labels above:"
  vmrun "sudo riptides daemon augment $NGINX_PID | grep -E '^systemd:(unit|description)=' || true"
  note "Run the app under docker instead (RT='sudo docker', needs the compose plugin)"
  note "to get docker:* selectors. This demo selects on process:* only, so it does"
  note "not depend on either."
fi
pause

step "The same for redis, a different binary in a different container"
REDIS_PID="$(vm 'pgrep -x redis-server | head -1' 2>/dev/null || true)"
if [[ -n "$REDIS_PID" ]]; then
  vmrun "sudo riptides daemon augment $REDIS_PID | grep -E '^(process:name|process:binary:path)=' || true"
else
  warn "no redis-server process found"
fi
pause

step "Meanwhile the kernel is already tracing every connection"
say "trace_all_sockets is on by default, so the flows exist before any policy does —"
say "with byte counts and hostnames, but no identity on them yet:"
conns 8080 "curl -s -o /dev/null http://127.0.0.1:8000/get"
conns 6379 "$RT exec demo-redis redis-cli -h 127.0.0.1 -p 6379 -r 10 -i 0.2 ping"
pause

step "That is the starting point"
say "Every flow is visible. None of it is authenticated, and no traffic is protected."
say "Nothing has been configured. The next act adds four small policy objects that"
say "match the labels above — and nothing else changes."
note "Next: make act2"
printf '\n'
