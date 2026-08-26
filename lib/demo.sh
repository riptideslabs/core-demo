#!/usr/bin/env bash
# Step runner. Everything is driven from your laptop:
#
#   * policy applies run here, with riptides-cli against the control plane;
#   * anything that has to see the kernel module, the containers or the wire
#     runs on the target through vm() — see lib/target.sh for lima vs ssh.
#
# Inside a string destined for the target use $TDIR, never $DEMO_DIR: they are
# the same path only when the demo directory is a shared mount.
#
# Set DEMO_NOPAUSE=1 to run an act end to end without waiting for a keypress.

set -euo pipefail

DEMO_DIR="${DEMO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# shellcheck source=lib/target.sh
source "$DEMO_DIR/lib/target.sh"
export CTL_BIN="${CTL_BIN:-riptides-cli}"
# The daemon's Prometheus endpoint — inside the VM, not on the Mac.
export METRICS_URL="${METRICS_URL:-http://localhost:50601/metrics}"
# Container runtime on the target. Lima ships containerd + nerdctl; an Amazon
# Linux box has docker (plus the compose plugin, once prepare-target has run).
# preflight.sh detects which and overrides this (see RT_USER_SET in target.sh:
# this default must not suppress that detection).
export RT="${RT:-sudo nerdctl}"
export COMPOSE="$RT compose -f $TDIR/app/compose.yaml"
# Same, plus the override that makes Redis serve its own TLS (act 2b).
export COMPOSE_PT="$COMPOSE -f $TDIR/app/compose.passthrough.yaml"

# GITHUB_PAT and any overrides live here, untracked.
if [[ -f "$DEMO_DIR/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  . "$DEMO_DIR/.env"
  set +a
fi

B=$'\033[1m'; DIM=$'\033[2m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; C=$'\033[36m'; N=$'\033[0m'

act() {
  printf '\n%s╭─────────────────────────────────────────────────────────────────────╮%s\n' "$C" "$N"
  printf '%s│%s %-67s %s│%s\n' "$C" "$B" "$1" "$C" "$N"
  printf '%s╰─────────────────────────────────────────────────────────────────────╯%s\n' "$C" "$N"
}

step() { printf '\n%s▸ %s%s\n' "$B" "$1" "$N"; }
say()  { printf '  %s\n' "$1"; }
note() { printf '  %s%s%s\n' "$DIM" "$1" "$N"; }
good() { printf '  %s✓ %s%s\n' "$G" "$1" "$N"; }
bad()  { printf '  %s✗ %s%s\n' "$R" "$1" "$N"; }
warn() { printf '  %s! %s%s\n' "$Y" "$1" "$N"; }

pause() {
  [[ -n "${DEMO_NOPAUSE:-}" ]] && return 0
  printf '\n  %s[enter]%s' "$DIM" "$N"
  read -r _ || true
  printf '\n'
}

# ── running things ──────────────────────────────────────────────────────────
# On the Mac.
runsh() {
  printf '  %s$ %s%s\n' "$DIM" "$1" "$N"
  bash -c "$1" 2>&1 | sed 's/^/    /'
}

# On the target, shown on screen. Append `|| true` inside CMD for steps that are
# expected to fail, or set -e will end the act.
vmrun() {
  printf '  %s[vm] $ %s%s\n' "$DIM" "$1" "$N"
  vm "$1" 2>&1 | sed 's/^/    /'
}

ctl() { "$CTL_BIN" ctl "$@"; }

# ── policy helpers ──────────────────────────────────────────────────────────
# Manifests are templates: ${TRUST_DOMAIN}, ${DAEMON_WORKLOAD_ID} and
# ${GITHUB_PAT} are substituted here, since CRDs have no server-side templating.
# The rendered manifest is piped straight in, so a secret never lands on disk.
apply() {
  local f="$1"
  printf '  %s$ envsubst < %s | %s ctl apply -f -%s\n' \
    "$DIM" "${f#"$DEMO_DIR"/}" "$CTL_BIN" "$N"
  envsubst < "$f" | ctl apply -f - 2>&1 | sed 's/^/    /'
}

apply_dir() {
  local d="$1" f
  for f in "$d"/*.yaml; do
    [[ "$(basename "$f")" == *-deny.yaml ]] && continue   # applied on demand
    apply "$f"
  done
}

delete() {
  local f="$1"
  envsubst < "$f" | ctl delete --ignore-not-found -f - 2>&1 | sed 's/^/    /' || true
}

# Delete the demo's policy from the control plane, newest dependency first.
#
# Acts 1 and 2 open by showing an unprotected wire, so left-over policy from an
# earlier run turns their opening evidence into a false negative — the capture
# shows zero plaintext and the narration says the opposite of the screen. Each
# act that makes such a claim clears what it needs first.
clear_policy() {
  local d f
  for d in "$@"; do
    # 20-binding before 1x-source/identity before 0x-service.
    for f in "$DEMO_DIR/policies/$d"/2*.yaml "$DEMO_DIR/policies/$d"/1*.yaml \
             "$DEMO_DIR/policies/$d"/0*.yaml; do
      [[ -e "$f" ]] && delete "$f"
    done
  done
}

# ── evidence helpers ────────────────────────────────────────────────────────
# One line per live connection: where to, and whether it carries identity.
# Sampled and filtered in the VM (lib/vm-conns.sh), which polls until a
# connection on the port is actually up — the proc file lists live sockets only.
conns() {
  local port="${1:-.}" generator="${2:-}"
  printf '  %s[vm] $ cat /proc/riptides/connections | jq   (port %s)%s\n' "$DIM" "$port" "$N"
  vm "bash '$TDIR/lib/vm-conns.sh' '$port' '$generator'" 2>&1 | sed 's/^/    /' || true
}

# tcpdump a few packets with payload, with a traffic generator alongside. The
# whole dance happens in one VM invocation (lib/vm-sniff.sh) so the tap and the
# generator cannot race across the host boundary.
sniff() {
  local port="$1" label="$2" generator="${3:-}"
  printf '  %s[vm] $ tcpdump -i lo -A port %s   (%s)%s\n' "$DIM" "$port" "$label" "$N"
  vm "bash '$TDIR/lib/vm-sniff.sh' '$port' '$generator'" 2>&1 | sed 's/^/    /' || true
}

# ngrep proof: is the plaintext still findable on the wire? Reports hits out of
# all packets seen, so "0" cannot be confused with "no traffic".
plaintext() {
  local port="$1" pattern="$2" generator="${3:-}" out rc
  printf '  %s[vm] $ payload count: "%s" on tcp port %s%s\n' "$DIM" "$pattern" "$port" "$N"
  # Output captured rather than piped so the helper's exit code survives: 2 means
  # it saw no packets, which is not a measurement and must not read as one.
  out="$(vm "bash '$TDIR/lib/vm-count.sh' '$port' '$pattern' '$generator'" 2>&1)"; rc=$?
  printf '%s\n' "$out" | sed 's/^/    /'
  return "$rc"
}

# Best effort. A daemon installed by the docs installer exports telemetry over
# OTLP to the control plane and may expose no local Prometheus endpoint at all,
# so this reports honestly instead of showing an empty grep.
metric() {
  local name="$1" url code
  for url in "$METRICS_URL" "http://localhost:50601/metrics" "http://localhost:50600/metrics"; do
    code="$(vm "curl -s -m 3 -o /dev/null -w '%{http_code}' '$url' 2>/dev/null || true")"
    if [[ "$code" == "200" ]]; then
      printf '  %s[vm] $ curl -s %s | grep %s%s\n' "$DIM" "$url" "$name" "$N"
      vm "curl -s -m 5 '$url' | grep '^$name' || true" | sed 's/^/    /'
      return 0
    fi
  done
  note "This daemon exposes no local Prometheus endpoint — it exports over OTLP to"
  note "the control plane, so the injection is counted there rather than here."
  note "Set METRICS_URL in .env if your daemon does serve /metrics."
}

# Policy distribution is a stream: it lands in well under a second, but never
# assume it already has.
settle() {
  local secs="${1:-4}"
  printf '  %s… waiting %ss for the policy to reach the kernel%s\n' "$DIM" "$secs" "$N"
  sleep "$secs"
}

# Poll the redis-cli loop until it reaches the expected state.
#
# Policy reaches the kernel in well under a second on a healthy control plane,
# but the loop only notices on its next reconnect, and a busy control plane adds
# more. Asserting after a fixed sleep printed "the client is refused" above four
# OK lines — the claim contradicting the screen. Wait for the observable instead.
#   await_redis <ok|fail> [seconds]
await_redis() {
  local want="$1" budget="${2:-45}" waited=0 line
  while :; do
    line="$(vm "$RT logs --tail 1 demo-redis-cli 2>&1" 2>/dev/null || true)"
    if [[ "$want" == "fail" && "$line" == *"redis FAIL"* ]]; then
      bad "refused after ${waited}s — ${line#* }"
      return 0
    fi
    if [[ "$want" == "ok" && "$line" == *"redis OK"* ]]; then
      good "recovered after ${waited}s, with nothing restarted"
      return 0
    fi
    if (( waited >= budget )); then
      warn "no change after ${budget}s; last line: ${line:-<none>}"
      return 1
    fi
    sleep 4
    waited=$((waited + 4))
  done
}

# Poll a GitHub /user response until it reaches the expected state, because
# credential updates are not reliably prompt: a Secret change sometimes lands in
# seconds and sometimes not at all until the daemon is restarted (its credential
# syncer stream flaps against the control plane). Returns the last answer seen.
#   await_github <authenticated|rejected> <seconds> <url>
await_github() {
  local want="$1" budget="${2:-60}" url="$3" waited=0 body login
  while :; do
    body="$(vm "$RT exec demo-client curl -sS -m 10 '$url' 2>/dev/null || true")"
    login="$(printf '%s' "$body" | jq -r '.login // empty' 2>/dev/null || true)"
    if [[ "$want" == "authenticated" && -n "$login" ]]; then
      printf '  %s✓ authenticated as %s after %ss%s\n' "$G" "$login" "$waited" "$N"
      return 0
    fi
    if [[ "$want" == "rejected" && -z "$login" ]]; then
      printf '  %s✗ %s after %ss%s\n' "$R" \
        "$(printf '%s' "$body" | jq -r '.message // "no answer"' 2>/dev/null)" "$waited" "$N"
      return 0
    fi
    if (( waited >= budget )); then
      warn "no change after ${budget}s — the credential did not reach the kernel."
      note "Last answer: $(printf '%s' "$body" | jq -r '.login // .message // "none"' 2>/dev/null)"
      note "This is the credential-propagation flakiness noted in the README, not"
      note "a policy error: check 'journalctl -u riptides | grep credential' for a"
      note "flapping syncer, and restart the daemon to force a re-fetch."
      return 1
    fi
    sleep 6
    waited=$((waited + 6))
  done
}

# Just the status code. curl writes 000 to stdout when the connection never
# completed; stderr is dropped so a refusal does not drag curl's and the
# runtime's error text onto the line.
http_code() {
  vm "$RT exec demo-client curl -sS -m 8 -o /dev/null -w '%{http_code}' '$1' 2>/dev/null || true"
}
