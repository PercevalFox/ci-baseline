# Pinning

## Why

`uses: some/action@v4` means "whatever the owner of that repository decides v4
points at, at the moment the job runs". Git tags are mutable and can be moved
to any commit by anyone with write access to that repository. That is a write
primitive into your CI, held by a third party.

In March 2025 the tags on `tj-actions/changed-files` were repointed at a commit
that dumped runner memory into the build log. Anything in memory — including
secrets — became publicly readable in the logs of every affected repository,
across tens of thousands of them. Repositories pinned to a commit SHA were
unaffected, because a SHA names an immutable object.

The same argument applies to reusable workflows, which are pulled in wholesale,
and to container images, where the digest is the SHA equivalent.

## The bootstrap

This repository ships with tag references, and `scripts/pin-actions.sh` fails
until they are resolved. That is intentional rather than an oversight: pinning
requires resolving each tag against the GitHub API, which needs network access
and credentials that belong to whoever is running it, not to whoever wrote the
file. Shipping placeholder SHAs would be worse — they would look verified.

```bash
make bootstrap    # resolves every tag to a commit SHA using gh(1)
git diff          # read this before committing it
```

The check then passes and stays in CI to keep it that way.

## Keeping pins current

A pinned SHA cannot change under you, which also means it does not receive
security fixes. Dependabot understands SHA-pinned actions and will open pull
requests that update both the SHA and the trailing version comment:

```yaml
# .github/dependabot.yml
version: 2
updates:
  - package-ecosystem: github-actions
    directory: /
    schedule:
      interval: weekly
```

The trailing comment is why `pin-actions.sh` warns when it is missing. A diff
of two forty-character hex strings is unreviewable; `# v4.2.2 -> # v4.3.0` is
the part a reviewer can actually judge.

## The allowlist

`PIN_ALLOWLIST` takes an extended regular expression matched against
`owner/repo`, and is empty by default.

The tempting exemption is `^actions/`, on the grounds that GitHub owns those
repositories. The argument does not hold up: the threat is a compromised
release process, and GitHub's is not categorically different from anyone
else's. The allowlist is there for repositories migrating gradually, not as a
resting state.
