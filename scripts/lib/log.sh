#!/usr/bin/env bash
# Shared helpers. Source this, do not execute it.
#
# Everything here degrades to plain stderr output when not running under
# GitHub Actions, so the same scripts are debuggable on a laptop. That is not
# a nicety: a CI script that can only be tested by pushing a commit gets
# tested by pushing forty commits.

# shellcheck shell=bash

# Guard against double-sourcing, which would redefine the trap handlers.
[[ -n "${__CI_BASELINE_LOG_SH:-}" ]] && return 0
__CI_BASELINE_LOG_SH=1

# GITHUB_ACTIONS is set to "true" by the runner. Anything else, including
# unset, means we are somewhere else and should not emit workflow commands.
_in_actions() { [[ "${GITHUB_ACTIONS:-}" == "true" ]]; }

log() {
  if _in_actions; then
    printf '::notice::%s\n' "$*"
  else
    printf '  %s\n' "$*" >&2
  fi
}

warn() {
  if _in_actions; then
    printf '::warning::%s\n' "$*"
  else
    printf 'warning: %s\n' "$*" >&2
  fi
}

err() {
  if _in_actions; then
    printf '::error::%s\n' "$*"
  else
    printf 'error: %s\n' "$*" >&2
  fi
}

die() {
  err "$@"
  exit 1
}

# group/endgroup produce collapsible sections in the Actions log. Worth using:
# a security job that prints four hundred lines is a job whose output nobody
# reads, and the interesting part is always the last twenty lines.
#
# Written as if/else rather than `cond && a || b`: that idiom runs the third
# branch whenever the second one fails, which for printf is unlikely but is
# the kind of thing that bites once and is then never found again.
group() {
  if _in_actions; then
    printf '::group::%s\n' "$*"
  else
    printf '\n== %s\n' "$*" >&2
  fi
}

endgroup() {
  if _in_actions; then
    printf '::endgroup::\n'
  fi
}

# set_output writes a step output. It writes only to $GITHUB_OUTPUT and prints
# nothing: printing is the caller's job, and having this function do both meant
# every value appeared twice when run outside Actions.
#
# The heredoc form is used rather than "key=value" because a value containing
# a newline would otherwise let an attacker append arbitrary extra outputs.
# None of the values this repository writes are attacker-controlled, but the
# safe form costs nothing and the unsafe one is a habit worth not having: the
# same pattern with a filename or a branch name in it is a real vulnerability.
set_output() {
  local key="$1" value="$2" delim
  [[ -n "${GITHUB_OUTPUT:-}" ]] || return 0

  # A random delimiter cannot be guessed by the value being written.
  delim="ghadelim_$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  {
    printf '%s<<%s\n' "$key" "$delim"
    printf '%s\n' "$value"
    printf '%s\n' "$delim"
  } >>"$GITHUB_OUTPUT"
}

# require_cmd fails early with a useful message rather than letting the script
# die forty lines later on "command not found".
require_cmd() {
  local cmd
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || die "required command not found: $cmd"
  done
}
