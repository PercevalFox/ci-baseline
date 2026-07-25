# Commenting on pull requests from forks

The short version: `pull_request_target` plus `actions/checkout` of the pull
request head is a remote code execution vulnerability, and this repository
avoids it by splitting the work across two workflows.

## Why the obvious approach is unsafe

A workflow triggered by `pull_request` from a fork gets a `GITHUB_TOKEN` with
read-only permissions and no access to secrets. That is correct and
deliberate: the job is about to run code written by someone who is not a
collaborator.

The consequence is that such a job cannot post a comment, which is annoying,
because a security report nobody sees is not a security control. Searching for
a solution leads quickly to `pull_request_target`, and the documentation for
it is accurate but easy to skim past.

`pull_request_target` runs the workflow definition from the *base* branch —
so an attacker cannot change what runs — but with a **write** token and full
access to secrets. The trap is in the checkout:

```yaml
# Do not do this.
on: pull_request_target

jobs:
  build:
    steps:
      - uses: actions/checkout@v4
        with:
          ref: ${{ github.event.pull_request.head.sha }}   # attacker's code
      - run: npm ci && npm test                            # ...now executing
```

By default `pull_request_target` checks out the base branch, which is safe.
Adding that `ref:` is what turns it dangerous, and it is added constantly,
because without it the job tests the wrong code and appears broken.

From there, anything that executes is executing as the attacker with a write
token in the environment: `npm ci` runs `postinstall` scripts from the pull
request's `package.json`, `make` runs the pull request's Makefile, a Python
build runs the pull request's `setup.py`. The token can push commits, and
`secrets` are readable from the environment.

This is usually called the "pwn request" pattern. It is not obscure — it has
been found repeatedly in large open-source projects, and it is one of the
first things any GitHub Actions audit looks for.

## What this repository does

Trust and privilege are put in different workflows.

```
security.yml                        pr-comment.yml
  on: pull_request                    on: workflow_run
  runs the untrusted code             never touches the code
  permissions: contents: read         permissions: pull-requests: write
  no secrets
        |                                     ^
        |  uploads gate.md as an artifact     |
        +-------------------------------------+
```

`security.yml` does everything that involves the pull request's contents,
under a read-only token. When it has a report to publish, it writes it to an
artifact and stops.

`pr-comment.yml` triggers on `workflow_run`, which is a repository-level event
that always executes the version of the file on the **default branch**. A pull
request cannot change it. It downloads the artifact, treats every byte of it as
untrusted input, and posts the comment. It never checks out the pull request
and never runs anything from it.

## Validating the artifact

The artifact was produced by a job that ran attacker-controlled code, so its
contents are attacker-controlled too. Two checks matter.

**The pull request number.** A fork can write any number into `pr-number`. If
that value is used directly, the attacker gets this repository to post a
comment, under its own identity, on any pull request they choose — including
in a different context where the comment might be trusted. So the number is
checked against reality: the artifact must also carry a head SHA, that SHA must
match `github.event.workflow_run.head_sha`, and the API must confirm the pull
request is actually at that commit.

**The body.** It is passed to `gh api` through `-F body=@file` rather than
being interpolated into a shell command. Interpolation with `${{ }}` happens
before the shell parses the line, so a body containing a quote and a semicolon
becomes a command. That is the same class of bug as the checkout above and is
just as common.

The body is also truncated at 60000 characters. GitHub rejects comments over
65536, and a scanner having a bad day should not turn into a failing job here.

## What this does not solve

- The comment can still be *wrong*, because a fork controls what the scanners
  see. It cannot be attributed to the wrong pull request, and it cannot execute
  anything, but a determined attacker can make their own pull request look
  clean. Anything that gates a merge should read the check status, not the
  comment.
- `workflow_run` jobs do not appear in the pull request's check list, so a
  failure to post is quiet. That is a deliberate trade: the alternative is
  giving the untrusted job the permission to report its own status.
- Artifacts from a fork run are still artifacts. Nothing sensitive should be
  written into them, which here means the comment body and two identifiers and
  nothing else.

## Further reading

- GitHub, *Keeping your GitHub Actions and workflows secure: Preventing pwn
  requests* — the original write-up of this pattern.
- GitHub Docs, *Security hardening for GitHub Actions*, particularly the
  sections on script injection and on `GITHUB_TOKEN` permissions.
