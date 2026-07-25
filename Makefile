SHELL := /bin/bash

.PHONY: check lint test bootstrap pin-check clean

check: lint test

lint:
	shellcheck -x scripts/*.sh scripts/lib/*.sh
	@command -v actionlint >/dev/null 2>&1 \
		&& actionlint \
		|| echo "actionlint not installed; skipping (go install github.com/rhysd/actionlint/cmd/actionlint@latest)"

test:
	bats tests/

# Resolve every tag reference to a commit SHA. Needs network access and gh(1),
# which is why this is a setup step rather than something shipped pre-done:
# placeholder SHAs would look verified without being verifiable.
bootstrap:
	@command -v gh >/dev/null 2>&1 || { echo "gh(1) is required; see https://cli.github.com"; exit 1; }
	# examples/ deliberately ships a <commit-sha> placeholder: it is
	# documentation showing consumers what to write, not a workflow that runs.
	scripts/pin-actions.sh --fix .github/workflows
	@echo
	@echo "Review the diff before committing:  git diff"

pin-check:
	scripts/pin-actions.sh .github/workflows

clean:
	rm -rf reports merged.sarif gate.md
