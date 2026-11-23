# zifiri — every entry point a fresh checkout needs, in one place.
#
#   make          list the targets below
#   make check    exactly what CI runs
#
# SHELL is pinned to bash so recipes behave the same on every host; a bare
# `sh` on this Windows host resolves the Elixir toolchain shim to the wrong
# install. MIX goes through the `command` builtin for the same reason: bash
# exec-optimises a recipe that is a single bare command, and the shim's
# shebang lookup then lands on a different Elixir/OTP pair.

SHELL := bash
MIX := command mix

.PHONY: help deps build test client serve static check audit

help: ## List the available targets
	@grep -hE '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-8s %s\n", $$1, $$2}'

deps: ## Fetch Hex dependencies
	$(MIX) deps.get

build: ## Compile the app, warnings treated as errors
	$(MIX) compile --warnings-as-errors

test: ## Run the ExUnit suite
	$(MIX) test

client: ## npm ci, vitest and vite build for client/
	cd client && npm ci && npm test && npm run build

serve: ## Start Phoenix on http://127.0.0.1:4000
	$(MIX) phx.server

static: ## Copy client/dist into priv/static (served by Plug.Static)
	@test -d client/dist || { echo "client/dist missing — run 'make client' first" >&2; exit 1; }
	rm -rf priv/static/assets priv/static/index.html client/dist
	cd client && npm run build
	cp -R client/dist/. priv/static/
	# `mix compile` copies priv/static into _build, and the server serves that
	# copy. Without this line a rebuilt bundle loses to the one in _build and the
	# browser keeps getting last week's CSS.
	rm -rf _build/dev/lib/zifiri/priv/static _build/test/lib/zifiri/priv/static
	@$(MIX) compile >/dev/null && echo "priv/static and _build refreshed"

check: ## Format check, compile and test — what CI runs
	$(MIX) format --check-formatted
	$(MIX) compile --warnings-as-errors
	$(MIX) test

audit: ## Scan Hex dependencies for known advisories
	$(MIX) deps.audit
