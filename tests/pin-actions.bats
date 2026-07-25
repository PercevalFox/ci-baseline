#!/usr/bin/env bats
#
# Tests for pin-actions.sh.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  PIN="$REPO_ROOT/scripts/pin-actions.sh"
  WORK="$(mktemp -d)"
  mkdir -p "$WORK/workflows"
  # Guard against the script losing its executable bit: without this, a
  # non-executable script exits 126 and every test asserting a non-zero
  # status passes for the wrong reason.
  [ -x "$PIN" ] || { echo "$PIN is not executable"; return 1; }
  unset GITHUB_ACTIONS PIN_ALLOWLIST
}

teardown() {
  rm -rf "$WORK"
}

workflow() {
  cat >"$WORK/workflows/$1"
}

@test "a SHA-pinned action passes" {
  workflow ok.yml <<'EOF'
jobs:
  build:
    steps:
      - uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683 # v4.2.2
EOF
  run "$PIN" "$WORK/workflows"
  [ "$status" -eq 0 ]
}

@test "a tag-pinned action fails" {
  # The whole point of the script.
  workflow bad.yml <<'EOF'
jobs:
  build:
    steps:
      - uses: actions/checkout@v4
EOF
  run "$PIN" "$WORK/workflows"
  [ "$status" -ne 0 ]
  [[ "$output" == *"mutable ref"* ]]
}

@test "a branch-pinned action fails" {
  workflow bad.yml <<'EOF'
jobs:
  build:
    steps:
      - uses: some/action@main
EOF
  run "$PIN" "$WORK/workflows"
  [ "$status" -ne 0 ]
}

@test "an action with no version at all fails" {
  workflow bad.yml <<'EOF'
jobs:
  build:
    steps:
      - uses: some/action
EOF
  run "$PIN" "$WORK/workflows"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no version at all"* ]]
}

@test "a local action is exempt" {
  # A path inside this repository is as trustworthy as the repository.
  workflow ok.yml <<'EOF'
jobs:
  build:
    steps:
      - uses: ./.github/actions/setup
EOF
  run "$PIN" "$WORK/workflows"
  [ "$status" -eq 0 ]
}

@test "a docker image without a digest fails" {
  workflow bad.yml <<'EOF'
jobs:
  build:
    steps:
      - uses: docker://alpine:3.20
EOF
  run "$PIN" "$WORK/workflows"
  [ "$status" -ne 0 ]
  [[ "$output" == *"digest"* ]]
}

@test "a docker image pinned by digest passes" {
  workflow ok.yml <<'EOF'
jobs:
  build:
    steps:
      - uses: docker://alpine@sha256:beefcafe0000000000000000000000000000000000000000000000000000dead
EOF
  run "$PIN" "$WORK/workflows"
  [ "$status" -eq 0 ]
}

@test "a short SHA is rejected" {
  # Seven hex characters is a prefix, and a prefix is resolvable to more than
  # one object once a repository is large enough.
  workflow bad.yml <<'EOF'
jobs:
  build:
    steps:
      - uses: actions/checkout@11bd719
EOF
  run "$PIN" "$WORK/workflows"
  [ "$status" -ne 0 ]
}

@test "an uppercase SHA is rejected" {
  # Git object names are lowercase; an uppercase value is not one, and
  # accepting it would let a tag named like a SHA through.
  workflow bad.yml <<'EOF'
jobs:
  build:
    steps:
      - uses: actions/checkout@11BD71901BBE5B1630CEEA73D27597364C9AF683
EOF
  run "$PIN" "$WORK/workflows"
  [ "$status" -ne 0 ]
}

@test "a pinned action without a version comment warns but passes" {
  # Readability control, not a security one.
  workflow ok.yml <<'EOF'
jobs:
  build:
    steps:
      - uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683
EOF
  run "$PIN" "$WORK/workflows"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no version comment"* ]]
}

@test "quoted references are handled" {
  workflow ok.yml <<'EOF'
jobs:
  build:
    steps:
      - uses: "actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683" # v4.2.2
      - uses: 'actions/setup-go@41dfa10bad2bb2ae585af6ee5bb4d7d973ad74ed' # v5.1.0
EOF
  run "$PIN" "$WORK/workflows"
  [ "$status" -eq 0 ]
}

@test "the allowlist exempts matching repositories" {
  workflow mixed.yml <<'EOF'
jobs:
  build:
    steps:
      - uses: actions/checkout@v4
      - uses: some/other@v1
EOF
  PIN_ALLOWLIST='^actions/' run "$PIN" "$WORK/workflows"
  [ "$status" -ne 0 ]
  # actions/* exempted, some/other still flagged.
  [[ "$output" == *"some/other"* ]]
  [[ "$output" != *"mutable ref 'v4': actions/checkout"* ]]
}

@test "every violation is reported, not just the first" {
  workflow bad.yml <<'EOF'
jobs:
  build:
    steps:
      - uses: a/one@v1
      - uses: b/two@v2
      - uses: c/three@main
EOF
  run "$PIN" "$WORK/workflows"
  [ "$status" -ne 0 ]
  [[ "$output" == *"3 unpinned"* ]]
}

@test "line numbers in the report point at the right line" {
  workflow bad.yml <<'EOF'
jobs:
  build:
    steps:
      - uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683 # v4.2.2
      - uses: bad/action@v1
EOF
  run "$PIN" "$WORK/workflows"
  [[ "$output" == *"bad.yml:5"* ]]
}

@test "a single file can be checked directly" {
  workflow ok.yml <<'EOF'
jobs:
  build:
    steps:
      - uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683 # v4.2.2
EOF
  run "$PIN" "$WORK/workflows/ok.yml"
  [ "$status" -eq 0 ]
}

@test "a directory with no workflows is an error" {
  mkdir -p "$WORK/empty"
  run "$PIN" "$WORK/empty"
  [ "$status" -ne 0 ]
}

@test "reusable workflow references are checked too" {
  # `uses:` at job level pulls in an entire workflow, so it matters at least
  # as much as a step-level action.
  workflow bad.yml <<'EOF'
jobs:
  security:
    uses: someorg/ci-baseline/.github/workflows/security.yml@main
EOF
  run "$PIN" "$WORK/workflows"
  [ "$status" -ne 0 ]
}

@test "a subdirectory action is reported under its full path" {
  # github/codeql-action/upload-sarif is the upload-sarif action inside the
  # github/codeql-action repository. The API only knows owner/repo, so --fix
  # has to trim the path for the lookup while rewriting the full reference.
  workflow bad.yml <<'YML'
jobs:
  build:
    steps:
      - uses: github/codeql-action/upload-sarif@v3
YML
  run "$PIN" "$WORK/workflows"
  [ "$status" -ne 0 ]
  [[ "$output" == *"github/codeql-action/upload-sarif"* ]]
}

@test "a placeholder reference is flagged but not treated as fixable" {
  # examples/ ships <commit-sha> on purpose; it is documentation.
  workflow example.yml <<'YML'
jobs:
  security:
    uses: someone/ci-baseline/.github/workflows/security.yml@<commit-sha>
YML
  run "$PIN" "$WORK/workflows"
  [ "$status" -ne 0 ]
  [[ "$output" == *"mutable ref"* ]]
}
