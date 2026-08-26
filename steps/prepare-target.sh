#!/usr/bin/env bash
# Install what the target box lacks, so the demo can run on it.
#
# Deliberately NOT part of `make up`: it mutates the host, so it stays an
# explicit, separate command you run once per box. Idempotent — it reports what
# it changed and skips what is already there.
#
# The gap this closes is Amazon Linux: it ships docker without the compose
# plugin, has no nerdctl at all, and has no ngrep in its default repos. A Lima
# VM needs none of this.
set -euo pipefail

DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/target.sh
source "$DEMO_DIR/lib/target.sh"
# shellcheck source=lib/demo.sh
source "$DEMO_DIR/lib/demo.sh"

COMPOSE_VERSION="${COMPOSE_VERSION:-v2.39.4}"

act "Preparing $TARGET_LABEL"

step "What is already there"
have() { vm "command -v $1 >/dev/null" 2>/dev/null; }
for t in docker jq tcpdump ngrep; do
  if have "$t"; then good "$t"; else warn "$t missing"; fi
done
if vm "sudo docker compose version >/dev/null 2>&1" 2>/dev/null \
   || vm "sudo nerdctl compose version >/dev/null 2>&1" 2>/dev/null; then
  good "a container runtime with compose support"
else
  warn "no runtime with compose support"
fi
pause

step "Packages from the distro"
# procps-ng/coreutils are named differently per family, hence target_pkg_for.
pkgs=""
for t in jq tcpdump; do have "$t" || pkgs="$pkgs $(target_pkg_for "$t")"; done
have docker || pkgs="$pkgs docker"
if [[ -n "${pkgs// /}" ]]; then
  vmrun "$(target_pkg_install_cmd)$pkgs 2>&1 | tail -3"
else
  say "nothing to install"
fi

step "ngrep"
# Not in the Amazon Linux 2023 repos, and EPEL coverage there is partial. Try the
# distro, then EPEL, then say so plainly: act 2 skips the counted evidence with a
# loud message rather than reporting a misleading zero, and tcpdump still gives
# the visual.
if have ngrep; then
  good "already installed"
elif vm "$(target_pkg_install_cmd) ngrep >/dev/null 2>&1" 2>/dev/null && have ngrep; then
  good "installed from the distro repos"
elif vm "sudo dnf install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm >/dev/null 2>&1 && sudo dnf install -y ngrep >/dev/null 2>&1" 2>/dev/null && have ngrep; then
  good "installed from EPEL"
else
  warn "could not install ngrep on this box."
  note "Act 2 will skip the counted before/after evidence and say so; tcpdump"
  note "still shows the payload becoming TLS records. Everything else is unaffected."
fi

step "docker compose plugin"
if vm "sudo docker compose version >/dev/null 2>&1" 2>/dev/null; then
  good "already present"
elif have docker; then
  # Amazon Linux packages docker without the plugin. The plugin is a single
  # binary dropped into docker's cli-plugins directory, per architecture.
  say "fetching the compose plugin ($COMPOSE_VERSION) for this box's architecture"
  vmrun "set -e
    arch=\$(uname -m)
    case \$arch in x86_64) a=x86_64 ;; aarch64|arm64) a=aarch64 ;; *) echo \"unsupported arch \$arch\"; exit 1 ;; esac
    sudo mkdir -p /usr/libexec/docker/cli-plugins
    sudo curl -fsSL -o /usr/libexec/docker/cli-plugins/docker-compose \\
      https://github.com/docker/compose/releases/download/$COMPOSE_VERSION/docker-compose-linux-\$a
    sudo chmod +x /usr/libexec/docker/cli-plugins/docker-compose
    sudo docker compose version | head -1"
else
  bad "docker is not installed, so the compose plugin cannot be placed"
fi

step "docker service"
if have docker; then
  vmrun "sudo systemctl enable --now docker >/dev/null 2>&1; systemctl is-active docker"
fi

step "Where that leaves the box"
runsh "DEMO_TARGET='$DEMO_TARGET' SSH_DEST='${SSH_DEST:-}' bash '$DEMO_DIR/lib/preflight.sh' 2>&1 | tail -12 || true"
note "riptides itself is not installed by this script — see the README for the"
note "one-liner. A join token works anywhere; on EC2 --awsiid joins on instance"
note "identity instead, but only once an AWSIID verifier exists in the console."
printf '\n'
