#!/usr/bin/env bash
# Assert the Mac and the VM are both ready, then resolve the two values every
# policy manifest needs. Sourced by the act scripts; also runnable on its own.
#
# Exports:
#   TRUST_DOMAIN         - the control plane's trust domain
#   DAEMON_WORKLOAD_ID   - this daemon's workload-ID path, for spec.scope.daemon.id
#
# Override either in the environment (or .env) to skip its lookup.

# Idempotent when sourced more than once. `return` is only valid in a sourced
# script, and the variable is only ever set by a previous source, so an executed
# run never reaches it.
if [[ -n "${_RIPTIDES_PREFLIGHT_DONE:-}" ]]; then
  return 0
fi

set -euo pipefail

DEMO_DIR="${DEMO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# shellcheck source=lib/target.sh
source "$DEMO_DIR/lib/target.sh"
CTL_BIN="${CTL_BIN:-riptides-cli}"

if [[ -f "$DEMO_DIR/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  . "$DEMO_DIR/.env"
  set +a
fi

_pf_ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
_pf_warn() { printf '  \033[33m!\033[0m %s\n' "$1"; }
_pf_die()  { printf '  \033[31m✗\033[0m %s\n' "$1" >&2; exit 1; }
_vm()      { vm "$1"; }

printf '\033[1mPreflight — this machine\033[0m\n'

for t in ssh tar jq envsubst "$CTL_BIN"; do
  command -v "$t" >/dev/null || _pf_die "$t is not on PATH"
done
_pf_ok "ssh, tar, jq, envsubst, $CTL_BIN present"

"$CTL_BIN" context status >/dev/null 2>&1 \
  || _pf_die "$CTL_BIN is not authenticated — run: $CTL_BIN context login"
_pf_ok "control plane: $("$CTL_BIN" context current 2>/dev/null || echo 'context unknown')"

printf '\n\033[1mPreflight — the target (%s)\033[0m\n' "$TARGET_LABEL"

if ! target_ready; then
  if [[ "$DEMO_TARGET" == "lima" ]]; then
    _pf_die "VM '$LIMA_VM' is not reachable — start it with: limactl start $LIMA_VM"
  else
    _pf_die "cannot ssh to $SSH_DEST — check SSH_DEST/SSH_KEY in .env"
  fi
fi
_pf_ok "target reachable"

# sudo runs unattended everywhere in the demo, so a password prompt would hang
# rather than fail. Check it up front.
_vm "sudo -n true" 2>/dev/null \
  || _pf_die "passwordless sudo is required on the target (true for ec2-user and Lima)"
_pf_ok "passwordless sudo"

# On lima the demo directory is a shared mount at the same path; on ssh it is
# copied. Either way the target must end up with a writable copy, because the
# compose files, policy templates and lib/vm-*.sh helpers are addressed by $TDIR.
if [[ -n "$TARGET_NEEDS_SYNC" ]]; then
  target_sync || _pf_die "could not copy the demo to $SSH_DEST:$TDIR"
  _pf_ok "demo copied to $TDIR"
else
  _vm "test -d '$TDIR' && test -w '$TDIR'" 2>/dev/null \
    || _pf_die "the VM cannot write $TDIR — make the Lima mount writable (limactl stop $LIMA_VM; limactl edit $LIMA_VM)"
  _pf_ok "demo directory shared and writable"
fi

health="$(_vm 'cat /sys/module/riptides/health 2>/dev/null || sudo cat /sys/module/riptides/health' 2>/dev/null || true)"
[[ "$health" == "OK" ]] \
  || _pf_die "driver health is '${health:-unreadable}', expected OK — check: systemctl status riptides-modules"
_pf_ok "driver health OK"

[[ "$(_vm 'systemctl is-active riptides' 2>/dev/null || true)" == "active" ]] \
  || _pf_die "the riptides daemon is not active — check: journalctl -u riptides -n 50"
_pf_ok "daemon active"

# Binary -> apt package, where they differ.
_pf_pkg() {
  case "$1" in
    pgrep)   echo procps ;;
    timeout) echo coreutils ;;
    *)       echo "$1" ;;
  esac
}

# Hard requirements. curl drives traffic and the readiness check, jq parses the
# connections file, pgrep finds the workload pids, timeout bounds the captures,
# riptides is the daemon binary act 1 calls for `daemon augment`.
# containerd/nerdctl is not listed: Lima always ships it, and the runtime is
# detected below anyway.
_pf_missing_req=()
for t in sudo curl jq pgrep timeout riptides; do
  _vm "command -v $t >/dev/null" 2>/dev/null || _pf_missing_req+=("$t")
done

# Evidence tools. An act still runs without these, minus one piece of proof, and
# the helpers say so out loud rather than reporting an empty capture — a missing
# ngrep would otherwise print "0 hits", which reads exactly like proof of
# encryption.
_pf_missing_opt=()
for t in tcpdump ngrep; do
  _vm "command -v $t >/dev/null" 2>/dev/null || _pf_missing_opt+=("$t")
done

if [[ ${#_pf_missing_req[@]} -gt 0 || ${#_pf_missing_opt[@]} -gt 0 ]]; then
  _pf_pkgs=()
  for t in "${_pf_missing_req[@]}" "${_pf_missing_opt[@]}"; do
    [[ "$t" == "riptides" ]] && continue      # not an apt package
    _pf_pkgs+=("$(_pf_pkg "$t")")
  done
  for t in "${_pf_missing_opt[@]}"; do
    if [[ "$t" == ngrep ]]; then
      _pf_warn "ngrep missing — the payload counts fall back to tcpdump (fine)"
    else
      _pf_warn "$t missing on the target — act 2 loses its payload counts"
    fi
  done
  if [[ ${#_pf_pkgs[@]} -gt 0 ]]; then
    _pf_names=()
    for t in "${_pf_pkgs[@]}"; do _pf_names+=("$(target_pkg_for "$t")"); done
    printf '    install on the target: %s %s\n' \
      "$(target_pkg_install_cmd)" "$(printf '%s ' "${_pf_names[@]}" | tr -s ' ' | sed 's/ $//')"
  fi
  if [[ ${#_pf_missing_req[@]} -gt 0 ]]; then
    printf '%s\n' "${_pf_missing_req[@]}" | grep -qx riptides \
      && _pf_warn "the riptides binary is missing — is this node actually joined? see https://docs.riptides.io/deployment/daemon-bare-metal/"
    _pf_die "missing on the target: ${_pf_missing_req[*]}"
  fi
else
  _pf_ok "VM tools present (curl, jq, pgrep, timeout, tcpdump, ngrep, riptides)"
fi

# Container runtime + compose. Lima ships containerd/nerdctl; this VM's docker
# has no compose plugin and needs root, so nerdctl is tried first.
if [[ -z "${RT_USER_SET:-}" ]]; then
  for cand in "sudo nerdctl" "sudo docker" "docker" "nerdctl"; do
    if _vm "$cand compose version >/dev/null 2>&1" 2>/dev/null; then
      RT="$cand"
      break
    fi
  done
fi
[[ -n "${RT:-}" ]] \
  || _pf_die "no container runtime with compose support on the target (tried nerdctl and docker)"
_pf_ok "container runtime: $RT"
export RT

# ── the two values every manifest needs ─────────────────────────────────────
printf '\n\033[1mResolved\033[0m\n'

# The driver publishes both, so this needs no control-plane round trip.
driver_config="$(_vm 'sudo cat /sys/module/riptides/config' 2>/dev/null || true)"
[[ -n "$driver_config" ]] || _pf_die "could not read /sys/module/riptides/config in the VM"

: "${TRUST_DOMAIN:=$(jq -r '.trust_domain // empty' <<<"$driver_config")}"
[[ -n "$TRUST_DOMAIN" ]] || _pf_die "no trust domain in /sys/module/riptides/config"
_pf_ok "trust domain: $TRUST_DOMAIN"

daemon_id="$(jq -r '.daemon_id // empty' <<<"$driver_config")"
[[ -n "$daemon_id" ]] || daemon_id="$(_vm 'sudo cat /var/lib/riptides/.daemonid' 2>/dev/null || true)"

# Retried: a single transient control-plane hiccup used to abort the whole run,
# and this control plane drops streams often enough for that to matter.
if [[ -z "${DAEMON_WORKLOAD_ID:-}" && -n "$daemon_id" ]]; then
  for _attempt in 1 2 3; do
    ctl_out="$("$CTL_BIN" ctl get daemons "$daemon_id" -o json 2>/dev/null || true)"
    DAEMON_WORKLOAD_ID="$(jq -r '.spec.workloadID // empty' <<<"$ctl_out" 2>/dev/null || true)"
    [[ -n "$DAEMON_WORKLOAD_ID" ]] && break
    sleep 3
  done
fi

if [[ -z "${DAEMON_WORKLOAD_ID:-}" ]]; then
  printf '\n  The control plane has no daemon named %s.\n\n' "${daemon_id:-<unknown>}"
  printf '  Daemons it does know about:\n'
  "$CTL_BIN" ctl get daemons 2>&1 | sed 's/^/    /' || true
  printf '\n  Pick the WORKLOAD ID column and re-run with:\n'
  printf '    DAEMON_WORKLOAD_ID=riptides/daemon/<uuid> make <target>\n\n'
  _pf_die "could not resolve DAEMON_WORKLOAD_ID"
fi
_pf_ok "daemon workload ID: $DAEMON_WORKLOAD_ID"

# ── interception CA for the containerised client ────────────────────────────
# TLS interception terminates the client's TLS with a cert from the driver's own
# CA. On the host that is invisible (riptides rewrites the system trust store in
# place); a container has its own, so the client gets a copy of the driver's
# bundle. Written from inside the VM into the shared mount, where compose.yaml
# picks it up as ./.ca/ca-certificates.crt.
# Written on the target, where compose mounts it from $TDIR/app/.ca. On lima the
# shared mount means the host sees it too; on ssh it stays remote, which is right.
_vm "mkdir -p '$TDIR/app/.ca' && { cat /sys/module/riptides/certs/ca-certificates.crt 2>/dev/null \
       || sudo cat /sys/module/riptides/certs/ca-certificates.crt; } \
     > '$TDIR/app/.ca/ca-certificates.crt'" 2>/dev/null || true
_pf_ca_n="$(_vm "grep -c 'BEGIN CERTIFICATE' '$TDIR/app/.ca/ca-certificates.crt' 2>/dev/null || echo 0" 2>/dev/null || echo 0)"
if [[ "${_pf_ca_n:-0}" -gt 0 ]]; then
  _pf_ok "interception CA bundle staged for the client container ($_pf_ca_n certs)"
else
  _pf_die "could not read /sys/module/riptides/certs/ca-certificates.crt on the target — act 3 needs it"
fi

export TRUST_DOMAIN DAEMON_WORKLOAD_ID
_RIPTIDES_PREFLIGHT_DONE=1
printf '\n'
