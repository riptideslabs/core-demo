#!/usr/bin/env bash
# Delete every object this demo created and restart the app clean, so the whole
# thing can be given again from act 1.
set -euo pipefail

DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$DEMO_DIR/lib/preflight.sh"
source "$DEMO_DIR/lib/demo.sh"

# Only needed so the Secret template renders; the value is irrelevant to a delete.
: "${GITHUB_PAT:=placeholder-for-templating-only}"
export GITHUB_PAT

act "Resetting"

step "Deleting the demo policy from the control plane"
# Reverse order: bindings before sources, identities before services.
for f in "$DEMO_DIR"/policies/04-passthrough/*.yaml \
         "$DEMO_DIR"/policies/03-inject/20-*.yaml \
         "$DEMO_DIR"/policies/03-inject/12-*.yaml \
         "$DEMO_DIR"/policies/03-inject/11-*.yaml \
         "$DEMO_DIR"/policies/03-inject/10-*.yaml \
         "$DEMO_DIR"/policies/03-inject/00-*.yaml \
         "$DEMO_DIR"/policies/02-mtls/1*.yaml \
         "$DEMO_DIR"/policies/02-mtls/00-*.yaml; do
  [[ -e "$f" ]] && delete "$f"
done

step "Verifying nothing is left"
# A delete that quietly failed is worse than a loud one: act 1 and act 2 both
# open by measuring a wire they assume is unprotected, so leftover policy turns
# their "before" reading into a false proof.
leftover=0
for kind in wid svc cb credsrc; do
  names="$(ctl get "$kind" -o name 2>/dev/null | grep -E '(^|/)demo-' || true)"
  if [[ -n "$names" ]]; then
    leftover=1
    bad "$kind still present:"
    printf '%s\n' "$names" | sed 's/^/      /'
  fi
done
if [[ "$leftover" -eq 1 ]]; then
  bad "the control plane still holds demo objects — delete them before running act 1,"
  bad "or act 2's \"before\" capture will show an already-encrypted wire."
  exit 1
fi
good "control plane clean"

step "Recreating the app so no connection or config survives"
# --force-recreate, not restart: `restart` would keep act 2b's TLS command on
# the Redis container, leaving act 2's "before" capture measuring an encrypted
# wire. Recreating from compose.yaml alone puts the plaintext leg back.
vmrun "$COMPOSE up -d --force-recreate 2>&1 | tail -1"

good "clean — 'make act1' starts over"
printf '\n'
