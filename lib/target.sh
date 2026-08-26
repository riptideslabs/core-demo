#!/usr/bin/env bash
# Where the demo runs its target-side commands, and where the demo directory
# lives as the target sees it. Sourced first by lib/preflight.sh and lib/demo.sh.
#
# Two targets, one transport. Lima is reachable over plain ssh using the config
# it generates itself, so there is a single implementation of vm() rather than one
# per target, and `limactl` is not needed on the run path at all.
#
#   DEMO_TARGET=lima   (default)  a local Lima VM
#   DEMO_TARGET=ssh               any joined Linux box: EC2, bare metal, a VM
#
# lima:  SSH config and destination are derived from LIMA_VM. The demo directory
#        is a writable mount at the same absolute path on both sides, so nothing
#        needs copying.
# ssh:   SSH_DEST is required (SSH_KEY and SSH_CONFIG optional). The demo
#        directory is copied to REMOTE_DIR, because there is no shared mount.
#
# Exports:
#   TDIR   the demo directory as the TARGET sees it — use this, not $DEMO_DIR,
#          inside any string that will be executed on the target
#   vm()   run a command on the target

[[ -n "${_RIPTIDES_TARGET_DONE:-}" ]] && return 0

DEMO_DIR="${DEMO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
export DEMO_DIR
# Did the operator actually choose a container runtime, or is RT about to be
# defaulted for them? Captured here because this file is sourced before anything
# else and only once: preflight must not skip detection just because demo.sh
# already filled RT in with a guess.
export RT_USER_SET="${RT:+1}"
export DEMO_TARGET="${DEMO_TARGET:-lima}"
export LIMA_VM="${LIMA_VM:-default}"

_tgt_ssh_opts=(
  -o BatchMode=yes
  -o StrictHostKeyChecking=accept-new
  -o LogLevel=ERROR
  # One handshake per run rather than one per call: an act makes ~15.
  -o ControlMaster=auto
  -o ControlPersist=60s
)

case "$DEMO_TARGET" in
lima)
  # Lima writes a ready-made ssh config per VM, ControlMaster included.
  SSH_CONFIG="${SSH_CONFIG:-$HOME/.lima/$LIMA_VM/ssh.config}"
  SSH_DEST="${SSH_DEST:-lima-$LIMA_VM}"
  # Shared mount: same absolute path on both sides, so no copying.
  TDIR="$DEMO_DIR"
  TARGET_NEEDS_SYNC=""
  TARGET_LABEL="Lima VM ($LIMA_VM)"
  ;;
ssh)
  [[ -n "${SSH_DEST:-}" ]] || {
    printf '  \033[31m✗\033[0m DEMO_TARGET=ssh needs SSH_DEST (e.g. ec2-user@1.2.3.4)\n' >&2
    printf '    set it in %s — see .env.example\n' "$DEMO_DIR/.env" >&2
    exit 1
  }
  # Default under the login user's home; no assumption about /opt or /srv.
  # Resolved to an absolute path below, because compose -f and the vm-*.sh
  # helpers are invoked with it and must not depend on the shell's cwd.
  TDIR="${REMOTE_DIR:-riptides-demo}"
  TARGET_NEEDS_SYNC=1
  TARGET_LABEL="$SSH_DEST"
  _tgt_resolve_home=1
  ;;
*)
  printf '  \033[31m✗\033[0m unknown DEMO_TARGET "%s" (expected lima or ssh)\n' "$DEMO_TARGET" >&2
  exit 1
  ;;
esac

[[ -n "${SSH_CONFIG:-}" && -r "${SSH_CONFIG:-}" ]] && _tgt_ssh_opts+=(-F "$SSH_CONFIG")
[[ -n "${SSH_KEY:-}" ]] && _tgt_ssh_opts+=(-i "$SSH_KEY" -o IdentitiesOnly=yes)

# vm() is defined below, so the absolute-path resolution happens after it.
export TARGET_NEEDS_SYNC TARGET_LABEL SSH_DEST

# Quote a string as a single word for the REMOTE shell.
#
# ssh hands its command to the target's login shell, which re-parses it — so
# `ssh host bash -lc "sudo id -u"` becomes `bash -lc sudo` with id and -u as $0
# and $1. limactl passed argv straight through and never had this problem, which
# is why it only shows up on the ssh transport, and only for multi-word commands.
_tgt_q() { printf "'%s'" "${1//\'/\'\\\'\'}"; }

# Run a command on the target. `bash -lc` so the login PATH applies, matching
# what an operator would get typing it themselves. stdin is left alone, because
# target_sync() pipes a tar stream through it.
vm() { ssh "${_tgt_ssh_opts[@]}" "$SSH_DEST" "bash -lc $(_tgt_q "$1")"; }

if [[ -n "${_tgt_resolve_home:-}" && "$TDIR" != /* ]]; then
  _tgt_home="$(vm 'printf %s "$HOME"' 2>/dev/null || true)"
  [[ -n "$_tgt_home" ]] && TDIR="$_tgt_home/$TDIR"
fi
export TDIR

# Copy the demo to the target. A no-op when the directory is already shared.
#
# tar over ssh rather than rsync: the payload is ~90 KB of shell and YAML, and
# rsync is not installed on a stock Amazon Linux box. Excludes are deliberate —
# .env holds the PAT and templating happens host-side, so the token never needs
# to reach the target; .ca and .certs are generated ON the target and would be
# clobbered by the host's copies; docs/ is a 300 KB diagram nothing there reads.
target_sync() {
  [[ -n "$TARGET_NEEDS_SYNC" ]] || return 0
  vm "mkdir -p '$TDIR'"
  tar -C "$DEMO_DIR" \
      --exclude='.env' --exclude='.git' --exclude='.DS_Store' \
      --exclude='docs' --exclude='app/.ca' --exclude='app/.certs' \
      -czf - . | vm "tar -C '$TDIR' -xzf -"
}

# Is the target reachable and, for lima, actually running?
target_ready() {
  if [[ "$DEMO_TARGET" == "lima" ]]; then
    command -v limactl >/dev/null || return 0   # ssh may still work without it
    [[ "$(limactl list --format '{{.Status}}' "$LIMA_VM" 2>/dev/null)" == "Running" ]] || return 1
  fi
  vm true >/dev/null 2>&1
}

# The target's package manager and the install command for it, so hints are
# right on Amazon Linux (dnf) as well as Debian/Ubuntu (apt-get).
target_pkg_install_cmd() {
  local mgr
  mgr="$(vm 'command -v dnf >/dev/null && echo dnf || { command -v apt-get >/dev/null && echo apt-get || echo unknown; }' 2>/dev/null || echo unknown)"
  case "$mgr" in
  dnf)     echo "sudo dnf install -y" ;;
  apt-get) echo "sudo apt-get install -y" ;;
  *)       echo "# install with your package manager:" ;;
  esac
}

# Binary -> package name, which differs per distro family.
target_pkg_for() {
  local bin="$1" mgr
  mgr="$(vm 'command -v dnf >/dev/null && echo dnf || echo apt' 2>/dev/null || echo apt)"
  case "$bin:$mgr" in
  pgrep:dnf)    echo procps-ng ;;
  pgrep:*)      echo procps ;;
  timeout:*)    echo coreutils ;;
  *)            echo "$bin" ;;
  esac
}

_RIPTIDES_TARGET_DONE=1
