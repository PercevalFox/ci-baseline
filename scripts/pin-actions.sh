#!/usr/bin/env bash
#
# Verify that every third-party action is pinned to a commit SHA.
#
# A tag is a mutable pointer. `uses: some/action@v4` means "whatever the owner
# of that repository decides v4 means at the moment your job runs", which is a
# write primitive into your CI from outside your organisation. This is not
# theoretical: in March 2025 the tj-actions/changed-files tags were repointed
# at a commit that dumped runner memory — including secrets — into the build
# log, across tens of thousands of repositories at once. Everyone pinned to a
# tag was affected; everyone pinned to a SHA was not.
#
# Usage:
#   pin-actions.sh [--fix] [path...]
#
# Without --fix this reports and exits non-zero, which is what CI wants.
# --fix rewrites tags to SHAs and needs network access and gh(1).
#
# Dependencies: coreutils, grep, sed. gh(1) only for --fix.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR source=lib/log.sh
source "$SCRIPT_DIR/lib/log.sh"

FIX=0
PATHS=()

while (( $# )); do
  case "$1" in
    --fix) FIX=1 ;;
    -h|--help)
      sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'
      exit 0
      ;;
    -*) die "unknown flag: $1" ;;
    *) PATHS+=("$1") ;;
  esac
  shift
done

(( ${#PATHS[@]} )) || PATHS=(.github/workflows)

# Actions exempt from the SHA requirement, as extended regular expressions
# matched against owner/repo.
#
# Empty by default, and that is the recommended setting. The obvious candidate
# for an exemption is actions/* on the grounds that GitHub owns it, but the
# argument does not hold: the threat is a compromised release process, and
# GitHub's is not categorically different from anyone else's. The exemption
# exists for repositories migrating gradually, not as a resting state.
ALLOWLIST_PATTERN="${PIN_ALLOWLIST:-}"

# A shell script is a poor YAML parser, and normally this would be the wrong
# tool. It is acceptable here because `uses:` has a rigid shape that does not
# vary with YAML style, and because the alternative is depending on yq, which
# means this cannot run on a minimal image. The known limitation is that a
# literal string containing "uses:" inside a run block would be flagged; that
# has not happened yet, and a false positive here is a two-second look at a
# diff rather than a missed vulnerability.
USES_RE='^[[:space:]]*(-[[:space:]]+)?uses:[[:space:]]*'

violations=0
checked=0
fixed=0

# classify decides what kind of reference a `uses:` value is.
classify() {
  local ref="$1"
  case "$ref" in
    ./*|.\\*)   printf 'local' ;;      # same-repository action
    docker://*) printf 'docker' ;;     # pinned by digest or not, handled below
    *)          printf 'remote' ;;
  esac
}

check_file() {
  local file="$1" line raw ref repo version lineno=0
  # Fixes are collected during the read and applied afterwards. Running sed -i
  # on the file the while loop is reading from leaves the read offset pointing
  # into a file whose contents have shifted underneath it, which silently skips
  # or repeats lines. shellcheck flags this as SC2094 and it is right to.
  local -a pending=()

  while IFS= read -r line; do
    lineno=$((lineno + 1))

    [[ "$line" =~ $USES_RE ]] || continue

    # Strip the key, surrounding quotes and any trailing comment, keeping the
    # comment separately because that is where the human-readable version goes.
    raw="${line#*uses:}"
    raw="${raw#"${raw%%[![:space:]]*}"}"   # ltrim
    ref="${raw%%#*}"
    ref="${ref%"${ref##*[![:space:]]}"}"   # rtrim
    ref="${ref%\"}"; ref="${ref#\"}"
    ref="${ref%\'}"; ref="${ref#\'}"

    [[ -n "$ref" ]] || continue
    checked=$((checked + 1))

    case "$(classify "$ref")" in
      local)
        # A path inside this repository is as trustworthy as the repository.
        continue
        ;;
      docker)
        if [[ "$ref" != *"@sha256:"* ]]; then
          err "$file:$lineno: container image not pinned by digest: $ref"
          violations=$((violations + 1))
        fi
        continue
        ;;
    esac

    repo="${ref%%@*}"
    version="${ref##*@}"

    if [[ -n "$ALLOWLIST_PATTERN" ]] && [[ "$repo" =~ $ALLOWLIST_PATTERN ]]; then
      log "$file:$lineno: $repo exempt by PIN_ALLOWLIST"
      continue
    fi

    if [[ "$ref" != *@* ]]; then
      err "$file:$lineno: no version at all: $ref"
      violations=$((violations + 1))
      continue
    fi

    if [[ ! "$version" =~ ^[0-9a-f]{40}$ ]]; then
      err "$file:$lineno: pinned to a mutable ref '$version': $repo"
      violations=$((violations + 1))
      pending+=("$repo@$version")
      continue
    fi

    # A bare SHA is secure but unreadable. Requiring the version comment means
    # a reviewer can tell v4.2.2 from v3.0.0 without opening a browser, which
    # is the difference between a dependency bump being reviewed and waved
    # through. Warning rather than error: it is a readability control, not a
    # security one.
    if [[ ! "$line" =~ \#[[:space:]]*v?[0-9] ]]; then
      warn "$file:$lineno: $repo pinned correctly but has no version comment"
    fi
  done <"$file"

  if (( FIX )); then
    local item
    for item in "${pending[@]}"; do
      if fix_pin "$file" "${item%@*}" "${item##*@}"; then
        fixed=$((fixed + 1))
      fi
    done
  fi
}

# fix_pin resolves a tag to its commit SHA and rewrites the file in place.
fix_pin() {
  local file="$1" repo="$2" version="$3" api_repo sha
  require_cmd gh

  # A placeholder in documentation is not resolvable and not meant to be.
  if [[ "$version" == *"<"* || "$version" == *">"* ]]; then
    log "$repo@$version is a placeholder, leaving it alone"
    return 1
  fi

  # An action may live in a subdirectory: github/codeql-action/upload-sarif
  # is the upload-sarif action inside the github/codeql-action repository.
  # The API only knows owner/repo, so the path has to be trimmed for the
  # lookup while the full reference is what gets rewritten in the file.
  api_repo="$(printf '%s' "$repo" | cut -d/ -f1,2)"
  if [[ "$api_repo" != */* ]]; then
    warn "not an owner/repo reference: $repo"
    return 1
  fi

  sha="$(gh api "repos/$api_repo/commits/$version" --jq '.sha' 2>/dev/null || true)"
  if [[ ! "$sha" =~ ^[0-9a-f]{40}$ ]]; then
    warn "could not resolve $api_repo@$version (does that tag exist?)"
    return 1
  fi

  # Anchored on the full old reference so a repository appearing twice with
  # different tags is not collapsed onto one SHA.
  sed -i "s|${repo}@${version}\([[:space:]]*\)\(#.*\)\?$|${repo}@${sha} # ${version}|" "$file"
  log "pinned $repo@$version -> $sha"
  return 0
}

group "Checking action pins"

files=()
for p in "${PATHS[@]}"; do
  if [[ -f "$p" ]]; then
    files+=("$p")
  elif [[ -d "$p" ]]; then
    while IFS= read -r f; do
      files+=("$f")
    done < <(find "$p" -maxdepth 1 -type f \( -name '*.yml' -o -name '*.yaml' \) | sort)
  else
    die "no such file or directory: $p"
  fi
done

(( ${#files[@]} )) || die "no workflow files found in: ${PATHS[*]}"

for f in "${files[@]}"; do
  check_file "$f"
done

endgroup

# In --fix mode the count that matters is what is left, not what was found.
# Reporting failure for references it just repaired made `make bootstrap &&
# git diff` never reach the diff, which is the one thing you want to read.
remaining=$(( violations - fixed ))

if (( remaining > 0 )); then
  err "$remaining unpinned reference(s) across ${#files[@]} file(s)"
  if (( ! FIX )); then
    printf 'Run with --fix to resolve tags to commit SHAs.\n' >&2
  fi
  exit 1
fi

if (( fixed )); then
  log "resolved $fixed reference(s) to commit SHAs; review the diff before committing"
  exit 0
fi

log "$checked reference(s) across ${#files[@]} file(s), all pinned"
