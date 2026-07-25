# Changelog

## [Unreleased]

## [0.1.0]

### Added
- Reusable `security.yml` callable with `workflow_call`, taking no secrets.
- Stack detection driving a dynamic scanner matrix, with vendored code and
  test fixtures excluded.
- `pr-comment.yml`: comments on fork pull requests through `workflow_run`,
  without granting write access to any job that ran the fork's code.
- `pin-actions.sh`: enforces commit-SHA pinning for actions, reusable
  workflows and container images. `--fix` resolves tags via `gh`.
- `actionlint-to-sarif.py`, so workflow problems reach the same gate as
  everything else instead of a separate job.
- Threat model, and documentation of the pwn request pattern.

### Fixed
- `set_output` printed the key/value pair as well as writing it to
  `$GITHUB_OUTPUT`, so every value appeared twice when run outside Actions and
  every caller parsing the output got two lines instead of one.
- `pin-actions.sh --fix` ran `sed -i` on the file its own `while` loop was
  reading from, leaving the read offset pointing into shifted content. Fixes
  are now collected during the pass and applied after the descriptor closes.
- Tests asserted only a non-zero exit status in several places, so a script
  that had lost its executable bit exited 126 and every negative test passed
  for the wrong reason. Setup now checks executability first.
- `pin-actions.sh --fix` passed the whole reference to the GitHub API, so an
  action living in a subdirectory (`github/codeql-action/upload-sarif`) could
  never be resolved: the API knows `owner/repo`, not the path within it.
- `--fix` reported failure for references it had just repaired, because the
  violation count was taken before fixing. `make bootstrap && git diff` never
  reached the diff, which is the one thing worth reading.
