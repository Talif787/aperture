# Aperture, single entry point for every common task.
#
# The rule for this file: if a task is run more than twice, it gets a target. A README
# full of copy-and-paste command lines drifts from reality within a month; a Makefile that
# CI also calls cannot drift, because CI would fail.

SHELL := /bin/bash
.DEFAULT_GOAL := help

IOS_DIR       := ios
CORE_PKG      := $(IOS_DIR)/Packages/ApertureCore
PLATFORM_PKG  := $(IOS_DIR)/Packages/AperturePlatform
BACKEND_DIR   := backend
COMPOSE       := infra/docker-compose.yml
SWIFT_IMAGE   ?= swift:6.3
UNAME         := $(shell uname -s)

.PHONY: help
help: ## Show this help
	@echo "Aperture development targets"
	@echo
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'
	@echo
	@echo "Platform: $(UNAME). Targets marked [macOS] require Xcode and are skipped elsewhere."

# ---------------------------------------------------------------- checks (any platform)

.PHONY: check
check: boundaries schema lint-config ## Everything that needs no Swift or Go toolchain

.PHONY: boundaries
boundaries: ## Enforce module boundaries and dependency acyclicity
	@python3 scripts/check_module_boundaries.py

.PHONY: schema
schema: ## Execute the sync queue DDL against SQLite and assert its behavior
	@python3 scripts/verify_queue_schema.py

.PHONY: lint-config
lint-config: ## Validate every YAML and JSON configuration file
	@python3 scripts/validate_configs.py

# ------------------------------------------------------------- Swift (Linux and macOS)

.PHONY: core-build
core-build: ## Build ApertureCore, which compiles on Linux and in Cloud Shell
	@cd $(CORE_PKG) && swift build

.PHONY: core-test
core-test: ## Test ApertureCore (domain, sync, contracts)
	@cd $(CORE_PKG) && swift test

.PHONY: core-test-verbose
core-test-verbose: ## Test ApertureCore with per-test output
	@cd $(CORE_PKG) && swift test --verbose

# ----------------------------------------------- Swift in Docker (no local toolchain)
#
# Cloud Shell gives 5 GB of $HOME and a Swift toolchain needs roughly 3 GB. Docker images
# live on the VM's ephemeral disk instead, so these targets cost nothing against that
# quota. They also run the exact image the CI job runs, which removes a class of
# "works on my machine" difference between local and CI results.
#
# Override the image with: make core-test-docker SWIFT_IMAGE=swift:6.2

DOCKER_SWIFT = docker run --rm \
	-u $(shell id -u):$(shell id -g) \
	-e HOME=/tmp \
	-v "$(CURDIR)/$(CORE_PKG)":/pkg \
	-w /pkg $(SWIFT_IMAGE)

.PHONY: core-build-docker
core-build-docker: ## Build ApertureCore in a container, no local Swift required
	@$(DOCKER_SWIFT) swift build

.PHONY: core-test-docker
core-test-docker: ## Test ApertureCore in a container, no local Swift required
	@$(DOCKER_SWIFT) swift test

.PHONY: core-shell-docker
core-shell-docker: ## Interactive shell in the Swift container, at the package root
	@docker run --rm -it -u $(shell id -u):$(shell id -g) -e HOME=/tmp \
		-v "$(CURDIR)/$(CORE_PKG)":/pkg -w /pkg $(SWIFT_IMAGE) bash

# --------------------------------------------------------------------- iOS [macOS only]

.PHONY: project
project: ## [macOS] Generate Aperture.xcodeproj from ios/project.yml
	@cd $(IOS_DIR) && xcodegen generate

.PHONY: platform-build
platform-build: ## [macOS] Build AperturePlatform
	@cd $(PLATFORM_PKG) && swift build

.PHONY: ios-build
ios-build: project ## [macOS] Build the app for the simulator
	@cd $(IOS_DIR) && xcodebuild build \
		-project Aperture.xcodeproj -scheme Aperture \
		-configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17' \
		-quiet

.PHONY: ios-test
ios-test: project ## [macOS] Run the iOS test suites on the simulator
	@cd $(IOS_DIR) && xcodebuild test \
		-project Aperture.xcodeproj -scheme Aperture \
		-destination 'platform=iOS Simulator,name=iPhone 17' \
		-quiet

# ------------------------------------------------------------------------------ backend

.PHONY: backend-build
backend-build: ## Build the Go service
	@cd $(BACKEND_DIR) && go build ./...

.PHONY: backend-test
backend-test: ## Run backend tests with the race detector
	@cd $(BACKEND_DIR) && go test -race -count=1 ./...

.PHONY: backend-lint
backend-lint: ## Lint the backend
	@cd $(BACKEND_DIR) && golangci-lint run

.PHONY: backend-run
backend-run: ## Run the service locally on :8080
	@cd $(BACKEND_DIR) && go run ./cmd/aperture

.PHONY: backend-up
backend-up: ## Start Postgres and the service in Docker
	@docker compose -f $(COMPOSE) up -d --build
	@echo "Service on http://localhost:8080  (health: /healthz, readiness: /readyz)"

.PHONY: backend-down
backend-down: ## Stop the local stack
	@docker compose -f $(COMPOSE) down

.PHONY: backend-logs
backend-logs: ## Tail the local stack logs
	@docker compose -f $(COMPOSE) logs -f

# ------------------------------------------------------------------------ database

.PHONY: db-status
db-status: ## What exists in the local database right now
	@./scripts/db.sh status

.PHONY: db-migrate
db-migrate: ## Apply migrations and create the application role
	@./scripts/db.sh migrate

.PHONY: db-baseline
db-baseline: ## Record existing migrations as applied, for a database created before tracking
	@./scripts/db.sh baseline

.PHONY: db-seed
db-seed: ## Insert the development fixtures
	@./scripts/db.sh seed

.PHONY: db-verify
db-verify: ## Prove tenant isolation adversarially, as the application role
	@./scripts/db.sh verify-rls

.PHONY: db-reset
db-reset: ## Destroy the volume and rebuild, migrate, and seed from nothing
	@./scripts/db.sh reset

.PHONY: db-psql
db-psql: ## Interactive psql as the bootstrap role
	@./scripts/db.sh psql

# ---------------------------------------------------------------------------- formatting

.PHONY: format
format: ## Format Swift and Go sources in place
	@command -v swiftformat >/dev/null 2>&1 && swiftformat . || echo "swiftformat not installed, skipping Swift"
	@command -v gofmt >/dev/null 2>&1 && gofmt -w $(BACKEND_DIR) || echo "gofmt not available, skipping Go"

.PHONY: lint
lint: ## Lint Swift sources
	@command -v swiftlint >/dev/null 2>&1 && swiftlint --strict || echo "swiftlint not installed, skipping"

# ------------------------------------------------------------------------------- codegen

.PHONY: generate
generate: ## Regenerate code from contracts/
	@./scripts/generate.sh

.PHONY: verify-generated
verify-generated: ## Fail if committed generated code differs from a fresh generation
	@./scripts/generate.sh
	@git diff --exit-code -- backend/gen ios/Packages/ApertureCore/Sources/ApertureContracts/Generated \
		|| (echo "Generated code is stale. Run 'make generate' and commit." && exit 1)

# --------------------------------------------------------------------------------- misc

.PHONY: doctor
doctor: ## Report what this machine can build, and what is missing
	@./scripts/doctor.sh

.PHONY: bootstrap
bootstrap: ## Set up a fresh clone for development
	@./scripts/bootstrap.sh

.PHONY: ci-local
ci-local: check backend-test ## Run what the pull request job runs, locally
	@if command -v swift >/dev/null 2>&1; then \
		$(MAKE) core-test; \
	else \
		echo "No local Swift toolchain, using the container instead"; \
		$(MAKE) core-test-docker; \
	fi

.PHONY: clean
clean: ## Remove build output
	@rm -rf $(CORE_PKG)/.build $(PLATFORM_PKG)/.build $(IOS_DIR)/Aperture.xcodeproj $(BACKEND_DIR)/bin
	@echo "Cleaned."
