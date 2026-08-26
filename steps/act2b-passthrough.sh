#!/usr/bin/env bash
# Act 2b — passthrough: the application brings its own TLS, and riptides
# authenticates the connection without decrypting it.
set -euo pipefail

DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$DEMO_DIR/lib/preflight.sh"
source "$DEMO_DIR/lib/demo.sh"

P="$DEMO_DIR/policies/04-passthrough"
M="$DEMO_DIR/policies/02-mtls"
CERTS="$TDIR/app/.certs"
PROBE="python3 $TDIR/app/redis-probe.py 127.0.0.1 6379 $CERTS/ca.crt"
# Held open long enough for a capture to catch it.
REDIS_GEN="$RT exec demo-redis redis-cli --tls --cacert /certs/ca.crt -h 127.0.0.1 -p 6379 -r 8 -i 0.2 ping"

act "Act 2b — passthrough: their TLS, our identity"

step "Turning on Redis' own TLS"
say "A throwaway CA and a server cert, because riptides cannot supply these:"
say "credential propagation delivers tokens and config files, not X.509 keypairs."
vmrun "bash $TDIR/app/gen-redis-certs.sh"
say "Redis now serves TLS on 6379 and the plaintext port is closed."
vmrun "$COMPOSE_PT up -d --force-recreate redis redis-cli 2>&1 | tail -1"
settle 8
vmrun "$RT exec demo-redis redis-cli --tls --cacert /certs/ca.crt -h 127.0.0.1 -p 6379 config get tls-port port"
vmrun "$RT logs --tail 2 demo-redis-cli"
pause

step "Clearing the Redis policy, to start from nothing again"
for f in "$P"/1*.yaml "$M"/12-*.yaml "$M"/13-*.yaml; do delete "$f"; done
settle 7
pause

step "Before: encrypted, and completely anonymous"
plaintext 6379 "demo:ts"
say "Zero hits — but riptides did not do that, the application did."
say "And when the app asks the kernel who it is talking to:"
vmrun "$PROBE"
say "Encryption without identity. Nothing can be authorized, because nobody"
say "knows who either end is."
pause

step "Applying the policy — the same MUTUAL policy as the plaintext leg"
say "Nothing in these manifests mentions passthrough. There is no such field:"
say "the proto carries one, but the daemon hardcodes it false and the setter is"
say "commented out. The driver works it out by watching the first sendmsg."
apply_dir "$P"
settle 8
pause

step "After: ask the kernel again"
vmrun "$PROBE"
good "ALPN riptides/passthrough, and both SPIFFE IDs"
say "riptides did the handshake, proved both identities, then restored the"
say "original sendmsg/recvmsg. It never held the plaintext, because there was"
say "none to hold."
pause

step "The same thing, visible on the wire"
plaintext 6379 "riptides/passthrough" "$REDIS_GEN"
say "That is the ALPN list in the ClientHello, in the clear. On the plaintext"
say "leg in act 2 it reads just 'riptides' — same code path, different answer."
pause

step "What the connection table shows"
conns 6379 "$REDIS_GEN"
warn "Note what is NOT here: tls/mtls look exactly as they did in act 2."
say "The connection table shows identity and that riptides manages the socket,"
say "but it cannot tell you the mode. Only the sockopt can."
pause

step "And the policy still bites"
say "Revoking redis-cli while riptides has never seen inside the traffic:"
apply "$P/91-wid-redis-deny.yaml"
await_redis fail 45 || true
say "Authorization enforced on a flow riptides never decrypted."
apply "$P/12-wid-redis.yaml"
await_redis ok 45 || true
pause

step "That is act 2b"
say "The objection this answers is \"we already do our own TLS\". Keep it: you"
say "still get workload identity on both ends and policy you can revoke, and"
say "riptides never becomes a party to your plaintext."
note "Back to the plaintext leg: make act2-plaintext"
printf '\n'
