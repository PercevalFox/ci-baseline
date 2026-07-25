#!/usr/bin/env bats
#
# Tests for detect-stack.sh.
#
# The interesting cases are not "does it find go.mod" but the exclusions: a
# vendored dependency or a test fixture turning on a scanner is how this kind
# of script becomes noise that everyone disables.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  DETECT="$REPO_ROOT/scripts/detect-stack.sh"
  WORK="$(mktemp -d)"
  # Not running under Actions, so no workflow commands and no GITHUB_OUTPUT.
  # Guard against the script losing its executable bit: without this, a
  # non-executable script exits 126 and every test asserting a non-zero
  # status passes for the wrong reason.
  [ -x "$DETECT" ] || { echo "$DETECT is not executable"; return 1; }
  unset GITHUB_ACTIONS GITHUB_OUTPUT
}

teardown() {
  rm -rf "$WORK"
}

# value extracts one key from the script's stdout.
value() {
  printf '%s\n' "$output" | grep "^$1=" | cut -d= -f2
}

@test "empty repository detects nothing but still scans for secrets" {
  run "$DETECT" "$WORK"
  [ "$status" -eq 0 ]
  [ "$(value go)" = "false" ]
  [ "$(value python)" = "false" ]
  # A repository with no recognised stack is exactly the one nobody has
  # looked at, so secret scanning is unconditional.
  [ "$(value secrets)" = "true" ]
}

@test "go.mod at the root turns on go" {
  touch "$WORK/go.mod"
  run "$DETECT" "$WORK"
  [ "$status" -eq 0 ]
  [ "$(value go)" = "true" ]
}

@test "vendored go.mod does not turn on go" {
  # The case that matters. Scanning vendored code produces findings the
  # repository cannot fix, and a wall of unfixable findings trains people to
  # ignore the whole job.
  mkdir -p "$WORK/vendor/github.com/some/dep"
  touch "$WORK/vendor/github.com/some/dep/go.mod"
  run "$DETECT" "$WORK"
  [ "$(value go)" = "false" ]
}

@test "node_modules does not turn on node" {
  mkdir -p "$WORK/node_modules/left-pad"
  touch "$WORK/node_modules/left-pad/package.json"
  run "$DETECT" "$WORK"
  [ "$(value node)" = "false" ]
}

@test "a fixture Dockerfile does not turn on container scanning" {
  # Security repositories deliberately contain broken examples.
  mkdir -p "$WORK/testdata/bad-images"
  touch "$WORK/testdata/bad-images/Dockerfile"
  run "$DETECT" "$WORK"
  [ "$(value docker)" = "false" ]
}

@test "monorepo services are found below the root" {
  mkdir -p "$WORK/services/api" "$WORK/services/worker"
  touch "$WORK/services/api/go.mod"
  touch "$WORK/services/worker/pyproject.toml"
  run "$DETECT" "$WORK"
  [ "$(value go)" = "true" ]
  [ "$(value python)" = "true" ]
}

@test "depth limit is honoured" {
  mkdir -p "$WORK/a/b/c/d/e/f/g/h"
  touch "$WORK/a/b/c/d/e/f/g/h/Cargo.toml"
  DETECT_MAX_DEPTH=3 run "$DETECT" "$WORK"
  [ "$(value rust)" = "false" ]

  DETECT_MAX_DEPTH=12 run "$DETECT" "$WORK"
  [ "$(value rust)" = "true" ]
}

@test "iac is derived from terraform, docker, helm or kubernetes" {
  touch "$WORK/main.tf"
  run "$DETECT" "$WORK"
  [ "$(value terraform)" = "true" ]
  [ "$(value iac)" = "true" ]
}

@test "iac is false when no infrastructure files exist" {
  touch "$WORK/go.mod"
  run "$DETECT" "$WORK"
  [ "$(value iac)" = "false" ]
}

@test "kubernetes is detected by content, not filename" {
  mkdir -p "$WORK/deploy"
  cat >"$WORK/deploy/thing.yaml" <<'EOF'
apiVersion: apps/v1
kind: Deployment
EOF
  run "$DETECT" "$WORK"
  [ "$(value kubernetes)" = "true" ]
  [ "$(value iac)" = "true" ]
}

@test "an ordinary yaml file is not mistaken for a kubernetes manifest" {
  mkdir -p "$WORK/deploy"
  cat >"$WORK/deploy/notes.yaml" <<'EOF'
environments:
  - staging
  - production
EOF
  run "$DETECT" "$WORK"
  [ "$(value kubernetes)" = "false" ]
}

@test "actions is scoped to .github/workflows, not any yml file" {
  touch "$WORK/config.yml"
  run "$DETECT" "$WORK"
  [ "$(value actions)" = "false" ]

  mkdir -p "$WORK/.github/workflows"
  touch "$WORK/.github/workflows/ci.yml"
  run "$DETECT" "$WORK"
  [ "$(value actions)" = "true" ]
}

@test "glob markers match variants" {
  touch "$WORK/requirements-dev.txt"
  run "$DETECT" "$WORK"
  [ "$(value python)" = "true" ]
}

@test "directory names containing spaces do not break detection" {
  mkdir -p "$WORK/my service"
  touch "$WORK/my service/go.mod"
  run "$DETECT" "$WORK"
  [ "$status" -eq 0 ]
  [ "$(value go)" = "true" ]
}

@test "output is sorted so run-to-run diffs are readable" {
  touch "$WORK/go.mod"
  run "$DETECT" "$WORK"
  keys="$(printf '%s\n' "$output" | grep '=' | cut -d= -f1)"
  sorted="$(printf '%s\n' "$keys" | sort)"
  [ "$keys" = "$sorted" ]
}

@test "a missing directory is an error, not a silent pass" {
  run "$DETECT" "$WORK/nope"
  [ "$status" -ne 0 ]
}

@test "writes to GITHUB_OUTPUT when set" {
  export GITHUB_OUTPUT="$WORK/out.txt"
  touch "$WORK/go.mod"
  run "$DETECT" "$WORK"
  [ "$status" -eq 0 ]
  grep -q '^go<<' "$WORK/out.txt"
  # The heredoc form is used so a value containing a newline cannot append
  # extra outputs. Nothing here is attacker-controlled, but the safe form
  # costs nothing.
  grep -qx 'true' "$WORK/out.txt"
}
