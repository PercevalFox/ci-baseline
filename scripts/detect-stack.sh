#!/usr/bin/env bash
#
# Decide which scanners a repository needs, by looking at what is in it.
#
# The alternative is asking every consuming repository to declare its stack in
# the workflow inputs. That gets written once, correctly, and is then wrong
# forever: the day someone adds a Dockerfile, nobody remembers to update the
# caller, and container scanning silently never runs. Detection is the option
# that fails toward scanning too much rather than too little.
#
# Output is `key=true|false` on stdout, and to $GITHUB_OUTPUT when set.
# Dependencies: coreutils and find. Deliberately not jq, so this runs on a
# minimal container image as well as on ubuntu-latest.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR source=lib/log.sh
source "$SCRIPT_DIR/lib/log.sh"

ROOT="${1:-.}"
MAX_DEPTH="${DETECT_MAX_DEPTH:-6}"

[[ -d "$ROOT" ]] || die "not a directory: $ROOT"

# Directories excluded from detection.
#
# vendor/ and node_modules/ matter most. A vendored go.mod would otherwise
# turn on Go dependency scanning for code the repository does not own and
# cannot patch, producing a permanent wall of findings that trains everyone to
# ignore the job. Third-party code is covered by the SCA scanners through the
# lockfile, which is the right place for it.
#
# testdata/ and fixtures/ are excluded because security tooling repositories
# deliberately contain broken examples, and a fixture Dockerfile should not
# trigger a container build.
EXCLUDED_DIRS=(
  .git
  node_modules
  vendor
  third_party
  testdata
  fixtures
  .venv
  venv
  dist
  build
  target
)

# build_prune_args turns the exclusion list into find(1) arguments. Built as an
# array rather than a string so directory names containing spaces survive.
build_prune_args() {
  local d first=1
  PRUNE_ARGS=(\()
  for d in "${EXCLUDED_DIRS[@]}"; do
    if (( first )); then
      first=0
    else
      PRUNE_ARGS+=(-o)
    fi
    PRUNE_ARGS+=(-name "$d")
  done
  PRUNE_ARGS+=(\) -prune)
}
build_prune_args

# find_marker reports whether any file matching the given patterns exists
# outside the excluded directories.
#
# -quit stops at the first hit. On a large monorepo the difference between
# stopping and walking the whole tree for each of a dozen markers is the
# difference between two seconds and a minute.
find_marker() {
  local pattern found
  for pattern in "$@"; do
    found="$(find "$ROOT" -maxdepth "$MAX_DEPTH" "${PRUNE_ARGS[@]}" -o \
      -type f -name "$pattern" -print -quit 2>/dev/null || true)"
    [[ -n "$found" ]] && return 0
  done
  return 1
}

# detect runs find_marker and records the result.
declare -A RESULTS=()
detect() {
  local key="$1"; shift
  if find_marker "$@"; then
    RESULTS["$key"]=true
  else
    RESULTS["$key"]=false
  fi
}

group "Detecting stack in $ROOT"

detect go        'go.mod' 'go.sum'
detect python    'requirements*.txt' 'pyproject.toml' 'Pipfile' 'setup.py' 'poetry.lock'
detect node      'package.json' 'package-lock.json' 'yarn.lock' 'pnpm-lock.yaml'
detect rust      'Cargo.toml'
detect java      'pom.xml' 'build.gradle' 'build.gradle.kts'
detect ruby      'Gemfile'
detect php       'composer.json'
detect dotnet    '*.csproj' '*.fsproj' '*.sln'

detect docker    'Dockerfile' 'Dockerfile.*' 'Containerfile' 'compose.yaml' 'docker-compose.yml'
detect terraform '*.tf'
detect helm      'Chart.yaml'
detect actions   '*.yml' # narrowed below

# The Actions check needs to be path-scoped, not name-scoped: every repository
# has .yml files, but only workflow files are worth linting with actionlint.
if [[ -d "$ROOT/.github/workflows" ]] &&
   find "$ROOT/.github/workflows" -maxdepth 1 -type f \( -name '*.yml' -o -name '*.yaml' \) -print -quit | grep -q .; then
  RESULTS[actions]=true
else
  RESULTS[actions]=false
fi

# Kubernetes manifests have no distinctive filename, so match on content.
# Restricted to two levels below a plausible directory to keep it cheap; this
# will miss manifests buried elsewhere, which is an accepted trade-off
# documented in the README rather than a bug.
RESULTS[kubernetes]=false
for dir in "$ROOT/k8s" "$ROOT/kubernetes" "$ROOT/manifests" "$ROOT/deploy"; do
  [[ -d "$dir" ]] || continue
  if grep -rlsE '^apiVersion:' --include='*.yaml' --include='*.yml' "$dir" 2>/dev/null | head -1 | grep -q .; then
    RESULTS[kubernetes]=true
    break
  fi
done

# IaC scanning covers several of the above; deriving it here means the caller
# does not have to remember which tools imply it.
if [[ "${RESULTS[terraform]}" == "true" || "${RESULTS[docker]}" == "true" ||
      "${RESULTS[kubernetes]}" == "true" || "${RESULTS[helm]}" == "true" ]]; then
  RESULTS[iac]=true
else
  RESULTS[iac]=false
fi

# Secret scanning and SAST always run. There is no marker file for "this
# repository might contain a credential", and a repository with no recognised
# stack is exactly the one nobody has looked at.
RESULTS[secrets]=true

# Emit sorted so the log is diffable between runs.
detected=()
for key in $(printf '%s\n' "${!RESULTS[@]}" | sort); do
  set_output "$key" "${RESULTS[$key]}"
  printf '%s=%s\n' "$key" "${RESULTS[$key]}"
  [[ "${RESULTS[$key]}" == "true" ]] && detected+=("$key")
done

endgroup

if (( ${#detected[@]} == 0 )); then
  warn "no stack detected; only secret scanning will run"
else
  log "detected: ${detected[*]}"
fi
