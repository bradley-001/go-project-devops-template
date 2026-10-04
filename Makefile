SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help

# Optional, for local overrides that should not be committed.
-include .env

ifneq ($(strip $(GITHUB_TOKEN)),)
export GITHUB_TOKEN
endif

GO ?= go

GOBIN := $(shell $(GO) env GOPATH)/bin
UV_BIN := $(shell command -v uv >/dev/null 2>&1 && uv tool dir --bin 2>/dev/null || echo "$(HOME)/.local/bin")
export PATH := $(GOBIN):$(UV_BIN):$(PATH)

BIN_DIR := ./bin
TMP_DIR := ./tmp
BINARY_NAME := <BINARY_NAME>
OUT := $(BIN_DIR)/$(BINARY_NAME)
PACKAGE_MAIN := ./cmd/$(BINARY_NAME)
COVERAGE := coverage.out
LOCAL_IMAGE := $(BINARY_NAME):local-latest

# main.go exits 1 when either symbol is unstamped, so a debug build has to set
# them too. The names are duplicated from .goreleaser.yaml, which owns the
# production flags.
VERSION ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo dev)
CHANNEL ?= dev
LDFLAGS := -X main.version=$(VERSION) -X main.environment=$(CHANNEL)

# ---------------------------------------------------------------------------
# Tool versions
# ---------------------------------------------------------------------------

# Read out of the workflows rather than repeated here, so a local run cannot
# disagree with the pipeline. Change them there, then run `make tools`.

CI_WORKFLOW := .github/workflows/ci.yml
RELEASE_WORKFLOW := .github/workflows/release.yml
wf_version = $(shell sed -n 's/^  $(1): *//p' $(2))

GOLANGCI_LINT_VERSION := $(call wf_version,GOLANGCI_LINT_VERSION,$(CI_WORKFLOW))
GOVULNCHECK_VERSION   := $(call wf_version,GOVULNCHECK_VERSION,$(CI_WORKFLOW))
OSV_SCANNER_VERSION   := $(call wf_version,OSV_SCANNER_VERSION,$(CI_WORKFLOW))
ACTIONLINT_VERSION    := $(call wf_version,ACTIONLINT_VERSION,$(CI_WORKFLOW))
GORELEASER_VERSION    := $(call wf_version,GORELEASER_VERSION,$(RELEASE_WORKFLOW))
SYFT_VERSION          := $(call wf_version,SYFT_VERSION,$(RELEASE_WORKFLOW))

# A failed parse silently installs @latest and drift from CI
ifeq ($(strip $(GOLANGCI_LINT_VERSION)),)
$(error Could not read GOLANGCI_LINT_VERSION from $(CI_WORKFLOW))
endif
ifeq ($(strip $(GOVULNCHECK_VERSION)),)
$(error Could not read GOVULNCHECK_VERSION from $(CI_WORKFLOW))
endif
ifeq ($(strip $(OSV_SCANNER_VERSION)),)
$(error Could not read OSV_SCANNER_VERSION from $(CI_WORKFLOW))
endif
ifeq ($(strip $(ACTIONLINT_VERSION)),)
$(error Could not read ACTIONLINT_VERSION from $(CI_WORKFLOW))
endif
ifeq ($(strip $(GORELEASER_VERSION)),)
$(error Could not read GORELEASER_VERSION from $(RELEASE_WORKFLOW))
endif
ifeq ($(strip $(SYFT_VERSION)),)
$(error Could not read SYFT_VERSION from $(RELEASE_WORKFLOW))
endif

# gitleaks and zizmor run in CI as actions, which pin an action version rather
# than a CLI version.

GITLEAKS_VERSION := v8.30.1
ZIZMOR_VERSION := 1.30.1

# Local only. Does not run in CI.
AIR_VERSION := v1.67.4

# actionlint bundles a schema predating `concurrency.queue` and reports the key in
# release.yml as unknown. That key stops a queued release being cancelled and
# losing a version.
ACTIONLINT_IGNORE := unexpected key "queue" for "concurrency" section

.PHONY: help build build-prod image run run-prod test lint format security check \
        dev configure tools clean clean-all

# ---------------------------------------------------------------------------
# Help
# ---------------------------------------------------------------------------

help: ## Show this help
	@echo "<PROJECT_NAME> commands"
	@echo "Go DevSecOps CI/CD and template built by bradley-001"
	@grep -hE '^[a-zA-Z0-9_-]+:.*?## ' $(MAKEFILE_LIST) \
		| sort \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'
	@echo

# ---------------------------------------------------------------------------
# Build and run
# ---------------------------------------------------------------------------

build: ## Build a debug binary into ./bin
	@mkdir -p $(BIN_DIR)
	@$(GO) build -gcflags=all='-N -l' -ldflags "$(LDFLAGS)" -o "$(OUT)" "$(PACKAGE_MAIN)"
	@echo "built $(OUT) (debug, no optimisation or inlining, steppable in delve)"

build-prod: ## Build a production binary into ./bin
	@command -v goreleaser >/dev/null || { echo "goreleaser missing. Run: make tools"; exit 1; }
	@mkdir -p $(BIN_DIR)
	@CHANNEL=dev goreleaser build --single-target --snapshot --clean --id "$(BINARY_NAME)" --output "$(OUT)"
	@echo "built $(OUT) (production)"

image: ## Build the local image from the working tree
	docker build -f Dockerfile.dev --build-arg LDFLAGS="$(LDFLAGS)" -t "$(LOCAL_IMAGE)" .
	@echo "built $(LOCAL_IMAGE)"

dev: ## Run with hot reload
	@command -v air >/dev/null || { echo "air missing. Run: make tools"; exit 1; }
	air

run: build ## Run the debug build
	@"$(OUT)"

run-prod: build-prod ## Run the production build
	@"$(OUT)"

# ---------------------------------------------------------------------------
# Test
# ---------------------------------------------------------------------------

test: ## Run the unit test suite
	$(GO) test -race -covermode=atomic -coverprofile="$(COVERAGE)" ./...

# ---------------------------------------------------------------------------
# Lint, format and security
# ---------------------------------------------------------------------------

lint: ## Lint Go sources and workflow definitions
	golangci-lint run
	@command -v shellcheck >/dev/null || { \
		echo "note: shellcheck not installed, so actionlint skips the shell script checks"; \
		echo "      CI runs. Install it from your package manager to match the pipeline."; \
	}
	actionlint -ignore '$(ACTIONLINT_IGNORE)'
	@[ -n "$${GITHUB_TOKEN:-}" ] || { \
		echo "note: GITHUB_TOKEN unset, so zizmor skips the online audits CI runs."; \
		echo "      A token with NO scopes is enough. It only lifts the API rate limit."; \
		echo "      Never put the configure token here."; \
		echo "      Put it in .env or the environment."; \
	}
	zizmor --format plain .
# Scans the repo root, matching CI: zizmor also audits dependabot.yml, not just workflows.

check: ## Run every gate a pull request must pass
	@$(MAKE) --no-print-directory format
	@$(MAKE) --no-print-directory lint
	@$(MAKE) --no-print-directory test
	@$(MAKE) --no-print-directory security
	@echo
	@echo "All gates passed."

format: ## Format the codebase in place
	golangci-lint fmt

security: ## Run the security scanners CI runs
	govulncheck ./...
	osv-scanner scan source --licenses="$$(sed -n '/^allow-licenses:/,/^[^ #-]/p' .github/dependency-review-config.yml | sed -n 's/^  - //p' | paste -sd, -)" -r ./
	gitleaks git --no-banner .

# ---------------------------------------------------------------------------
# Environment
# ---------------------------------------------------------------------------

configure: ## First-time setup: fill the template, configure GitHub, install tooling
	@./scripts/configure.sh
	@$(MAKE) --no-print-directory tools

tools: ## Install the CI, release and local tooling
	$(GO) mod download
	@echo "CI-mirrored tooling:"
	$(GO) install "github.com/golangci/golangci-lint/v2/cmd/golangci-lint@$(GOLANGCI_LINT_VERSION)"
	$(GO) install "golang.org/x/vuln/cmd/govulncheck@$(GOVULNCHECK_VERSION)"
	$(GO) install "github.com/google/osv-scanner/v2/cmd/osv-scanner@$(OSV_SCANNER_VERSION)"
	$(GO) install "github.com/rhysd/actionlint/cmd/actionlint@$(ACTIONLINT_VERSION)"
	$(GO) install "github.com/zricethezav/gitleaks/v8@$(GITLEAKS_VERSION)"
	@command -v uv >/dev/null || { echo "uv missing. See https://docs.astral.sh/uv/"; exit 1; }
	uv tool install --force "zizmor==$(ZIZMOR_VERSION)"
	@echo
	@echo "Release-pipeline tooling (versions from $(RELEASE_WORKFLOW)):"
	$(GO) install "github.com/goreleaser/goreleaser/v2@$(GORELEASER_VERSION)"
	$(GO) install "github.com/anchore/syft/cmd/syft@$(SYFT_VERSION)"
	@echo
	@echo "Local-only tooling:"
	$(GO) install "github.com/air-verse/air@$(AIR_VERSION)"
	@echo
	@echo "Done."
	@case ":$$PATH:" in \
		*":$(GOBIN):"*) ;; \
		*) echo; \
		   echo "$(GOBIN) is not on your shell PATH. Every make target still works,"; \
		   echo "since the Makefile adds it. To run the tools directly, add:"; \
		   echo; \
		   echo "  export PATH=\"\$$PATH:$(GOBIN)\"" ;; \
	esac

clean: ## Remove build artefacts and caches
	rm -rf "$(BIN_DIR)" "$(TMP_DIR)" ./dist
	rm -f "$(COVERAGE)" "./$(BINARY_NAME)" ./*.sarif "./$(BINARY_NAME)-sbom".*.json
	$(GO) clean -cache -testcache

clean-all: clean ## Also remove the module cache
	@echo "Removing the shared module cache."
	$(GO) clean -modcache
