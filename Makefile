# Riptides capability demo. Run these on the joined node.
#
#   make check   preflight only: is this host a joined riptides node?
#   make up      start the app (no policy applied — act 1 needs none)
#   make act1    augmentation
#   make act2    mTLS between two internal services
#   make act3    secret injection on egress
#   make reset   delete the demo policy, restart the app clean
#   make down    stop the app (riptides itself is left alone)
#
# DEMO_NOPAUSE=1 runs an act end to end without waiting for a keypress.

SHELL := /usr/bin/env bash
STEPS := $(CURDIR)/steps
LIMA_VM ?= default
# Container runtime inside the VM. The scripts auto-detect this; it is only
# needed here for the targets that do not source lib/preflight.sh.
RT ?= sudo nerdctl

.PHONY: help check up act1 act2 act3 act2-passthrough act2-plaintext all reset down logs shell sync prepare-target
.DEFAULT_GOAL := help

help: ## List available targets
	@grep -hE '^[a-zA-Z0-9_-]+:.*?## ' $(MAKEFILE_LIST) \
	 | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-17s\033[0m %s\n", $$1, $$2}'

check: ## Preflight: driver health, control-plane auth, resolved policy values
	@bash $(CURDIR)/lib/preflight.sh

up: ## Start the five app containers
	@bash $(STEPS)/up.sh

act1: ## Act 1 — augmentation
	@bash $(STEPS)/act1-augmentation.sh

act2: ## Act 2 — mTLS between two internal services
	@bash $(STEPS)/act2-mtls.sh

act3: ## Act 3 — secret injection on egress
	@bash $(STEPS)/act3-injection.sh

act2-passthrough: ## Act 2b — Redis brings its own TLS, riptides passes it through
	@bash $(STEPS)/act2b-passthrough.sh

act2-plaintext: ## Undo act 2b: put the Redis leg back to plaintext
	@bash $(STEPS)/act2-plaintext.sh

all: up act1 act2 act3 ## Run everything in order

reset: ## Delete the demo policy and restart the app
	@bash $(STEPS)/reset.sh

down: ## Stop and remove the app containers
	@bash $(STEPS)/down.sh

logs: ## Tail the daemon's log on the target
	@bash -c 'source $(CURDIR)/lib/target.sh; vm "sudo journalctl -u riptides -f"'

shell: ## Open a shell on the target, in the demo directory
	@bash -c 'source $(CURDIR)/lib/target.sh; exec ssh $${SSH_CONFIG:+-F $$SSH_CONFIG} $$SSH_DEST -t "cd $$TDIR 2>/dev/null; exec bash -l"'

sync: ## Copy the demo to the target (no-op when it is a shared mount)
	@bash -c 'source $(CURDIR)/lib/target.sh; target_sync && echo "  synced to $${TARGET_LABEL}:$${TDIR}"'

prepare-target: ## Install what the target lacks (docker+compose, jq, tcpdump, ngrep)
	@bash $(STEPS)/prepare-target.sh
