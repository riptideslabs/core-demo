#!/usr/bin/env bash
# Act 3 — a GitHub PAT injected on egress, never present in the workload.
set -euo pipefail

DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$DEMO_DIR/lib/preflight.sh"
source "$DEMO_DIR/lib/demo.sh"

P="$DEMO_DIR/policies/03-inject"
GH_URL="https://api.github.com/user"

if [[ -z "${GITHUB_PAT:-}" ]]; then
  bad "GITHUB_PAT is not set"
  note "cp $DEMO_DIR/.env.example $DEMO_DIR/.env and put a GitHub PAT in it"
  note "(a token with no scopes at all is enough — /user only needs to authenticate)"
  exit 1
fi

# GitHub answers "Requires authentication" when no Authorization header arrives
# and "Bad credentials" when one arrives but is wrong. That difference is the
# proof of injection, independent of whether the token itself is any good.
gh_body() { vm "$RT exec demo-client curl -sS -m 10 '$GH_URL' 2>/dev/null || true"; }

act "Act 3 — the credential the workload never has"

# Idempotent: the act opens by claiming the client cannot authenticate, so it has
# to start from nothing. Left-over policy from an earlier run would make the
# first request succeed and turn the narration into a lie.
step "Starting from nothing"
clear_policy 03-inject
settle 8

step "The client container, before anything is applied"
vmrun "$RT exec demo-client env | grep -iE 'token|pat|auth|secret|key' || echo '(nothing credential-shaped in the environment)'"
say "It cannot authenticate to GitHub:"
say "  HTTP $(http_code "$GH_URL")"
vmrun "$RT exec demo-client curl -sS -m 10 $GH_URL 2>/dev/null | head -3 || true"
say "Remember that message — \"Requires authentication\" means GitHub saw no"
say "Authorization header at all."
pause

step "Step 1 of 2: the destination, the secret, the source, the identity"
say "All four first: the binding's admission webhook rejects it unless both its"
say "CredentialSource and a WorkloadIdentity with a matching workloadID exist."
apply "$P/00-service-github.yaml"
apply "$P/10-secret.yaml"
apply "$P/11-credentialsource.yaml"
apply "$P/12-wid-client.yaml"
runsh "$CTL_BIN ctl get credsrc demo-github-pat"
pause

step "Step 2 of 2: the binding that ties them together"
apply "$P/20-credentialbinding.yaml"
settle 6
runsh "$CTL_BIN ctl get cb demo-github-pat"
pause

step "The same command, unchanged"
body="$(gh_body)"
printf '%s\n' "$body" | head -12 | sed 's/^/    /'
if printf '%s' "$body" | jq -e '.login' >/dev/null 2>&1; then
  good "authenticated as $(printf '%s' "$body" | jq -r '.login') — and the container still has no token in it"
elif printf '%s' "$body" | grep -q 'Bad credentials'; then
  warn "\"Bad credentials\", not \"Requires authentication\" — the header WAS injected,"
  warn "GitHub just rejected the token. Put a valid PAT in .env to get a 200."
else
  bad "unexpected response — see above"
fi
pause

step "Where the header came from"
say "curl's own trace of what it wrote to the socket:"
vmrun "$RT exec demo-client curl -sS -o /dev/null -v $GH_URL 2>&1 | grep -E '^> (GET|Host|User-Agent|Accept|Authorization)' || true"
say "No Authorization line. curl never sent one — the kernel added it after curl"
say "handed the bytes to the socket. That is also why this connection had to be"
say "intercepted (tls.intercept on the egress rule) to be writable at all, and"
say "why the client trusts the driver's CA."
vmrun "$RT exec demo-client env | grep -iE 'token|pat|secret' || echo '(still nothing credential-shaped in the environment)'"
pause

step "Where else this shows up"
say "The driver counts every injection as riptides_driver_credential_injection_total:"
metric riptides_driver_credential_injection_total
pause

step "Rotation: change the secret, change nothing else"
say "Re-applying the same Secret with a deliberately broken value:"
GITHUB_PAT="ghp_this_token_is_not_valid_0000000000" apply "$P/10-secret.yaml"
await_github rejected 60 "$GH_URL" || true
say "The workload was not touched: no restart, no redeploy, no new config."
say "And back to the configured one:"
apply "$P/10-secret.yaml"
if ! await_github authenticated 60 "$GH_URL"; then
  # Known, reproducible: editing the Secret behind an existing CredentialSource
  # does not reliably reach the daemon — no credential event is delivered even
  # with V(2) logging and a healthy watch stream, and a daemon restart does not
  # clear it. Recreating the source does. Do that on screen rather than leaving
  # the demo dead, and name it for what it is.
  warn "Falling back to re-creating the CredentialSource, which does propagate."
  for f in "$P/20-credentialbinding.yaml" "$P/11-credentialsource.yaml" "$P/10-secret.yaml"; do
    delete "$f"
  done
  settle 8
  for f in "$P/10-secret.yaml" "$P/11-credentialsource.yaml" "$P/20-credentialbinding.yaml"; do
    apply "$f"
  done
  await_github authenticated 90 "$GH_URL" || true
fi
pause

step "That is act 3"
say "The workload asked for api.github.com and the request was authenticated for"
say "it. The token lived in the control plane and was applied on the wire, in the"
say "kernel. It was never in the image, the environment, a file, or the process."
note "Console: the credential binding, and the intercepted egress flow in the connection inventory"
note "Teardown: make reset (drops the demo policy) or make down (also stops the app)"
printf '\n'
