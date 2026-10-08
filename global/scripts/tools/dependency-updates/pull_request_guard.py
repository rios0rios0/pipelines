#!/usr/bin/env python3
"""Decide whether the dependency-updates workflow may rewrite its pull-request branch.

The workflow regenerates the branch from the default branch on every run. That
is what keeps it rebased and its diff exactly the current set of updates -- and
it is a force-push, so two situations make it wrong. Both are decisions a person
made, and both would be silently undone:

  DECLINED      a pull request proposing this exact set of updates was closed
                without merging. Proposing it again twice a week would turn a
                "no" into a nag. A newer release changes the set, and with it
                the fingerprint, and is proposed normally.
  HAND-EDITED   the branch carries a commit somebody pushed: any non-merge
                commit without the `Dependency-Updates-Fingerprint:` trailer the
                workflow writes into its own. Merge commits are exempt, because
                GitHub's "Update branch" button makes one and regenerating the
                branch only redoes what it did.

Prints `proceed=true|false` and `reason=...`, for `$GITHUB_OUTPUT`. A lookup
that fails exits 2 and decides nothing: not knowing whether a person declined
something is not permission to propose it again.

Stdlib only, and it shares `check_updates.py`'s transport, so its offline
fixture answers by URL in the same way (`GET <url>`, `null` for a 404).
"""

from __future__ import annotations

import argparse
import os
import re
import sys
import urllib.parse

from check_updates import MARKER, TRAILER, Lookups, LookupError_, NotFound, github_headers, read_fixture

FINGERPRINT = re.compile(r"^[0-9a-f]{64}$")
REPOSITORY = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")


def decide(lookups: Lookups, api: str, repository: str, branch: str, base: str, fingerprint: str) -> tuple[bool, str]:
    owner = repository.split("/", 1)[0]
    closed = lookups.json("%s/repos/%s/pulls?state=closed&head=%s&per_page=100" % (
        api, repository, urllib.parse.quote("%s:%s" % (owner, branch), safe="")), github_headers()) or []
    marker = "<!-- %s %s -->" % (MARKER, fingerprint)
    for pull in closed:
        if pull.get("merged_at"):
            continue
        if marker in (pull.get("body") or ""):
            return False, ("these exact updates were declined in #%s, which was closed without merging; they are "
                           "proposed again once upstream releases something newer" % pull.get("number"))
    try:
        compare = lookups.json("%s/repos/%s/compare/%s...%s" % (
            api, repository, urllib.parse.quote(base, safe="/"), urllib.parse.quote(branch, safe="/")),
            github_headers()) or {}
    except NotFound:
        return True, "the branch does not exist yet"
    for commit in compare.get("commits") or []:
        if len(commit.get("parents") or []) > 1:
            continue
        message = (commit.get("commit") or {}).get("message") or ""
        if TRAILER not in message:
            return False, ("%s carries %s, a commit this workflow did not write; the branch is left alone until its "
                           "pull request is merged or closed" % (branch, (commit.get("sha") or "")[:12]))
    return True, "the branch holds only this workflow's own commits"


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--repository", default=os.environ.get("GITHUB_REPOSITORY"), help="owner/name")
    parser.add_argument("--branch", required=True, help="the branch the pull request is opened from")
    parser.add_argument("--base", required=True, help="the branch the pull request targets")
    parser.add_argument("--fingerprint", required=True, help="the fingerprint `check_updates.py --apply` wrote")
    parser.add_argument("--fixture", default=os.environ.get("DEPENDENCY_UPDATES_FIXTURE"),
                        help="JSON of `GET <url>` answers; makes the run offline")
    args = parser.parse_args(argv)

    if not args.repository or not REPOSITORY.match(args.repository):
        print("ERROR: --repository must be owner/name, got %r" % args.repository, file=sys.stderr)
        return 2
    if not FINGERPRINT.match(args.fingerprint):
        print("ERROR: --fingerprint must be 64 hex characters, got %r" % args.fingerprint, file=sys.stderr)
        return 2
    # GitHub Enterprise Server answers on its own host; GitHub.com sets this too.
    api = (os.environ.get("GITHUB_API_URL") or "https://api.github.com").rstrip("/")
    lookups = Lookups(read_fixture(args.fixture) if args.fixture else None)
    try:
        proceed, reason = decide(lookups, api, args.repository, args.branch, args.base, args.fingerprint)
    except LookupError_ as error:
        print("ERROR: could not tell whether the pull request may be updated: %s" % error, file=sys.stderr)
        return 2
    print("proceed=%s" % ("true" if proceed else "false"))
    print("reason=%s" % reason)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
