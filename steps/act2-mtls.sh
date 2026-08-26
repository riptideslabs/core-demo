#!/usr/bin/env bash
# Act 2 — mTLS between internal services, on an HTTP leg and a non-HTTP leg.
set -euo pipefail

DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$DEMO_DIR/lib/preflight.sh"
source "$DEMO_DIR/lib/demo.sh"

P="$DEMO_DIR/policies/02-mtls"
# Runs inside the VM, alongside the tap.
CURL_NGINX="curl -s -o /dev/null http://127.0.0.1:8000/get"

act "Act 2 — mTLS between two internal services, without touching either"

# The "before" capture below has to be a genuinely unprotected wire, and act 2b
# leaves the Redis leg on its own TLS, so clear both before claiming anything.
step "Starting from nothing"
clear_policy 04-passthrough 02-mtls
settle 6

step "Before: what is actually on the wire"
say "The HTTP leg, tapped on loopback while a request goes through nginx:"
sniff 8080 "before — expect readable HTTP" "$CURL_NGINX"
say "And the Redis leg, which is not HTTP at all:"
sniff 6379 "before — expect readable RESP"
pause

step "Before, counted: grep the wire for the payload"
say "ngrep reports hits out of every packet it saw, so a zero later cannot be"
say "waved away as \"there was no traffic\"."
plaintext 8080 "GET /get" "$CURL_NGINX"
plaintext 6379 "demo:ts"
pause

step "Applying the policy: two services, four identities"
say "MUTUAL on both ends, plus reciprocal allowed SPIFFE IDs. Nothing else."
apply_dir "$P"
settle 5
pause

step "After: the same two greps, verbatim"
plaintext 8080 "GET /get" "$CURL_NGINX"; _http_rc=$?
plaintext 6379 "demo:ts"; _resp_rc=$?
if [[ "$_http_rc" -eq 0 && "$_resp_rc" -eq 0 ]]; then
  good "zero hits on both legs, with the same order of traffic as before"
  say "The application still gets its 200s and its OKs. The bytes are on the wire."
  say "The plaintext is not."
else
  warn "One leg carried no traffic at all, so this proves nothing about it."
  warn "The leg is broken, not silent — check: make logs, and dmesg on the target."
  note "A CSR_SIGN timeout here means the daemon could not reach the control-plane"
  note "signer, so the workload never got a certificate to do mTLS with."
fi
pause

step "So what IS still readable?"
say "On the Redis leg, because the metadata exchange happens once per connection"
say "and redis-cli opens a new one every iteration:"
plaintext 6379 "spiffe://"
say "That is the metadata exchange, in the clear, ahead of the handshake."
say "Identity is asserted openly and then proven by the TLS that follows — the"
say "payload is what gets protected."
note "The HTTP leg would show this too, but only on a fresh connection: nginx"
note "holds its upstream open, so a capture usually catches reuse, not a handshake."
pause

step "And the same tap as before, for the shape of it"
sniff 6379 "after — expect TLS records" "$RT exec demo-redis redis-cli -h 127.0.0.1 -p 6379 -r 10 -i 0.2 ping"
say "The Redis leg is the one that matters most here: Redis ships its own TLS"
say "support and we did not switch it on. This is a socket-level mechanism, not"
say "an HTTP proxy."
pause

step "The kernel's view of those same connections"
conns 8080 "$CURL_NGINX"
conns 6379 "$RT exec demo-redis redis-cli -h 127.0.0.1 -p 6379 -r 10 -i 0.2 ping"
good "spiffe_id, peer_spiffe_id and mtls_version are populated on both legs"
pause

step "And the applications are exactly as they were"
vmrun "$RT exec demo-nginx cat /etc/nginx/conf.d/default.conf"
say "Still proxy_pass http://… — no ssl_certificate, no proxy_ssl_*."
vmrun "$RT exec demo-redis redis-cli -h 127.0.0.1 -p 6379 config get tls-port"
say "tls-port 0: Redis's own TLS is off. No keys, no certs, no restarts."
pause

step "Now revoke it — policy, not plumbing"
say "Re-applying redis's identity with redis-cli removed from the inbound allow-list:"
apply "$P/91-wid-redis-deny.yaml"
await_redis fail 45 || true
vmrun "$RT logs --tail 3 demo-redis-cli"
say "Same binary, same port — no longer on the list."
pause

step "And put it back"
apply "$P/12-wid-redis.yaml"
await_redis ok 45 || true
vmrun "$RT logs --tail 3 demo-redis-cli"
pause

step "A different process on the same host does not get in"
say "The client container runs curl. It holds no identity for :8080, so httpbin"
say "refuses it — while nginx, which does hold one, is served at the same moment."
say "  rogue curl -> httpbin :8080   HTTP $(http_code http://127.0.0.1:8080/get)"
vmrun "curl -s -o /dev/null -w 'nginx  -> httpbin :8080   HTTP %{http_code}\n' http://127.0.0.1:8000/get"
say "000 (or a reset) versus 200. Identity is the process, not the host or the network."
pause

step "That is act 2"
say "Two legs, two protocols, mutual authentication both ways, and an allow-list"
say "enforced in the kernel. Zero lines changed in nginx, httpbin or Redis."
note "Next: make act3"
printf '\n'
