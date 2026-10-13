#!/usr/bin/env bash
# Delete every object this demo created and restart the app clean, so the whole
# thing can be given again from act 1.
set -euo pipefail

DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$DEMO_DIR/lib/preflight.sh"
source "$DEMO_DIR/lib/demo.sh"

act "Resetting"

step "Deleting the demo policy from the control plane"
purge_policy

step "Verifying nothing is left"
# A delete that quietly failed is worse than a loud one: act 1 and act 2 both
# open by measuring a wire they assume is unprotected, so leftover policy turns
# their "before" reading into a false proof.
if ! policy_clean; then
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
