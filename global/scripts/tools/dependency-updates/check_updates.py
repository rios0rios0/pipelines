#!/usr/bin/env python3
"""Report every pinned third-party dependency that has a newer version upstream, and with `--apply` rewrite it.

WHY THIS EXISTS

Everything this repository executes is pinned: actions to a commit SHA, images
to a digest, binaries to a version plus a committed SHA-256, packages to an
exact release. That is what makes a pipeline reproducible, and it is also what
makes it go stale silently -- a pin never tells you it is three CVEs behind. The
whole point of pinning is that nothing moves without a human deciding it should,
so the missing half is something that tells the human when to decide.

This is that half. It reads the pins out of the repository, asks each upstream
what the current version is, and reports every one that differs. With `--apply`
it also does the work the decision used to cost, so what reaches a person is a
pull request to review rather than a list to work through by hand.

WHAT IT CHECKS

  actions   `uses: owner/repo@<sha> # vX.Y.Z` -> newer release for owner/repo
  images    `name:tag@sha256:...`             -> the tag now resolves elsewhere
  manifest  `*_PINNED_VERSION` / `*_SPEC`     -> newer version upstream
  inline    the same value written twice      -> the two copies disagree

Images are checked by DIGEST rather than by tag, because that is the question
worth asking of a container: `python:3.13-slim` is rebuilt with patched system
packages under the same tag, so "is there a newer tag" would miss every security
rebuild, while "does this tag still resolve to the bytes we pinned" catches them
all. The tag is deliberately not resolved to a "latest" -- choosing to move from
`python:3.13` to `3.14` is a decision, not an update.

WHAT `--apply` WRITES

  actions   the commit SHA the new release tag points at, and its `# vX.Y.Z`
  images    the digest the pinned tag resolves to now
  manifest  the new version, and every `*_SHA256_*` that belongs to it
  inline    every copy of a manifest value, so a template with no SCRIPTS_DIR
            cannot be left behind on the version the manifest just left

plus the pull request's title, body and commit message under the report
directory, and a changelog entry in the repository. It never commits, pushes or
merges anything: the workflow opens the pull request, and a person decides.

A new digest is never guessed and an old one is never carried forward. It is the
SHA-256 GitHub recorded for the release asset -- or the SHA-256 of the
downloaded bytes, for a release published before GitHub recorded any -- it must
match the publisher's checksum manifest when the pin names one, and the
`# asset:` template that located it must first reproduce the committed digest
for the CURRENT version. That last check is what proves the template names the
file the installer really verifies. A pin that fails any of them is left exactly
as it is and listed as needing a person; nothing is ever written half-updated.

FAIL-SAFE DIRECTION

A lookup that cannot be completed is reported as an ERROR and fails the run. It
must never be silently treated as "up to date": a rate-limited GitHub API would
otherwise turn this whole check into a green light that inspected nothing, which
is worse than not running it at all.
"""

from __future__ import annotations

import argparse
import collections
import concurrent.futures
import dataclasses
import datetime
import fnmatch
import hashlib
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

USER_AGENT = "rios0rios0-pipelines-dependency-check"
TIMEOUT = 30
# A checksum manifest is a few kilobytes; anything near this is not one.
MAX_DOCUMENT_BYTES = 8 * 1024 * 1024
# Only an asset GitHub recorded no digest for is downloaded -- a release
# published before GitHub started recording them -- and those are small. The cap
# is what makes a template pointed at the wrong file fail here, loudly, instead
# of filling the runner's disk.
MAX_DOWNLOAD_BYTES = 512 * 1024 * 1024

# --------------------------------------------------------------------------- #
# Version handling
# --------------------------------------------------------------------------- #
# Upstreams spell the same release differently: `v0.11.0` and `0.11.0`,
# `codeql-bundle-v2.26.3` and `2.26.3`. Normalising both sides before comparing
# is what keeps this from reporting an "update" from a version to itself.
PREFIXES = ("codeql-bundle-v", "codeql-bundle-", "v")


def normalise(version: str) -> str:
    version = (version or "").strip()
    for prefix in PREFIXES:
        if version.startswith(prefix):
            return version[len(prefix):]
    return version


def parts(version: str) -> tuple:
    """Numeric components of a version, for ordering.

    Falls back to a string comparison for anything not dotted-numeric -- Go
    pseudo-versions (`v0.0.0-20160331181800-b5bfa59ec0ad`) and the SonarScanner
    image's `12.1.0.3233_8.0.1` both land here, and for those "different" is the
    only judgement worth making.
    """
    cleaned = normalise(version)
    chunks = re.split(r"[.\-_+]", cleaned)
    numeric = []
    for chunk in chunks:
        if chunk.isdigit():
            numeric.append(int(chunk))
        else:
            break
    return tuple(numeric)


def is_newer(pinned: str, latest: str) -> bool:
    """True when `latest` is a release beyond `pinned`.

    Compares only as many components as the PIN declares, which is what makes a
    major-only pin work: `wrangler@4` against `4.123.0` is current, against
    `5.0.0` is not. A pin of `4.1` is judged on major+minor, and a full
    `1.2.3` on all three.
    """
    pinned_parts, latest_parts = parts(pinned), parts(latest)
    if not pinned_parts or not latest_parts:
        return normalise(pinned) != normalise(latest)
    width = min(len(pinned_parts), len(latest_parts))
    return latest_parts[:width] > pinned_parts[:width]


# ASCII, so `\d` means what `[0-9]` meant: a version is never spelt in Arabic-Indic digits.
FAMILY = re.compile(r"^(?P<family>\D*?)v?\d", re.ASCII)
MAJOR_ONLY = re.compile(r"\d+", re.ASCII)


def tag_family(tag: str) -> str | None:
    """The release line a tag belongs to: `codeql-bundle` for `codeql-bundle-v2.27.2`, empty for `v4.38.3`.

    One repository can publish two unrelated release lines. `github/codeql-action`
    tags the action `v4.x` and the CodeQL bundle `codeql-bundle-v2.x`, and marks
    whichever shipped last as its latest release -- so asking for "the latest
    release" answered the action pin with a bundle version, which compares as
    OLDER, and the action read as current at v4.37.7 while v4.38.3 was out. The
    bundle pin is exposed the same way the next time an action release ships
    last. Comparing only within one family is what keeps the two lines apart.

    `v4.38.3` and `4.38.3` are the same family: a leading `v` is spelling, not a
    release line, and the manifest drops it from versions whose tags carry it.
    """
    match = FAMILY.match(tag or "")
    if not match:
        return None
    return match.group("family").rstrip("-_.")


def is_major_only(version: str) -> bool:
    """A pin naming a major alone (`wrangler@4`): a deliberate range, not an exact build."""
    return MAJOR_ONLY.fullmatch(normalise(version)) is not None


def restyle(current: str, latest: str) -> str:
    """Write `latest` the way the pin already writes `current`.

    Upstream tags carry prefixes the pins do not (`v8.31.0` for a pin written
    `8.30.1`) and the reverse (`codeql-bundle-v2.27.2` IS the pin), and a
    major-only pin (`wrangler@4`) is a deliberate range rather than an exact
    build. Each pin keeps its own shape: the prefix it already has, and its
    width when it names a major alone.
    """
    prefix = current[: len(current) - len(normalise(current))]
    value = normalise(latest)
    if is_major_only(current):
        latest_parts = parts(latest)
        if latest_parts:
            value = str(latest_parts[0])
    return prefix + value


def is_major(current: str, new: str) -> bool:
    current_parts, new_parts = parts(current), parts(new)
    return bool(current_parts and new_parts and current_parts[0] != new_parts[0])


# --------------------------------------------------------------------------- #
# HTTP
# --------------------------------------------------------------------------- #
class LookupError_(Exception):
    """An upstream could not be consulted. Never treated as 'up to date'."""


class NotFound(LookupError_):
    """The upstream answered, and what was asked for does not exist.

    Kept apart from a failed lookup because the two call for different things.
    A release asset that answers 404 is a definite answer -- usually an upstream
    renaming its assets, which the installer has to follow by hand -- while a
    timeout says nothing at all and must never be read as "absent".
    """


class HttpsOnlyRedirects(urllib.request.HTTPRedirectHandler):
    """Follow a redirect only to another https URL, and never carry a token to a new host.

    Release downloads redirect to a CDN. urllib follows a redirect into plain
    HTTP by default, which would let whoever answers it choose the bytes being
    hashed -- the downgrade `verify-download.sh` closes with
    `--proto-redir '=https'`. And urllib copies every header onto the
    redirected request, `Authorization` included, so a token meant for
    api.github.com would follow a redirect to whichever host it named.
    """

    def redirect_request(self, req, fp, code, msg, headers, newurl):  # noqa: D102 - urllib's contract
        if urllib.parse.urlsplit(newurl).scheme != "https":
            raise urllib.error.HTTPError(newurl, code, "refused a redirect away from https", headers, fp)
        redirected = super().redirect_request(req, fp, code, msg, headers, newurl)
        if redirected is not None and (
                urllib.parse.urlsplit(newurl).hostname != urllib.parse.urlsplit(req.full_url).hostname):
            redirected.remove_header("Authorization")
        return redirected


OPENER = urllib.request.build_opener(HttpsOnlyRedirects)


def _request(url: str, headers: dict | None = None, method: str = "GET"):
    if urllib.parse.urlsplit(url).scheme != "https":
        raise LookupError_("%s -> refusing a URL that is not https" % url)
    request = urllib.request.Request(url, method=method)
    request.add_header("User-Agent", USER_AGENT)
    for key, value in (headers or {}).items():
        request.add_header(key, value)
    return OPENER.open(request, timeout=TIMEOUT)  # noqa: S310 - https enforced above


def _http_error(url: str, error: urllib.error.HTTPError) -> LookupError_:
    if error.code == 404:
        return NotFound("%s -> HTTP 404" % url)
    if error.code in (403, 429):
        return LookupError_("%s -> HTTP %s (rate limited; set GITHUB_TOKEN)" % (url, error.code))
    return LookupError_("%s -> HTTP %s" % (url, error.code))


def _read(url: str, headers: dict | None, limit: int) -> bytes:
    try:
        with _request(url, headers) as response:
            data = response.read(limit + 1)
    except urllib.error.HTTPError as error:
        raise _http_error(url, error) from error
    except LookupError_:
        raise
    except Exception as error:  # noqa: BLE001 - any transport failure is a lookup failure
        raise LookupError_("%s -> %s" % (url, error)) from error
    if len(data) > limit:
        raise LookupError_("%s -> larger than %d bytes" % (url, limit))
    return data


def get_json(url: str, headers: dict | None = None):
    data = _read(url, headers, MAX_DOCUMENT_BYTES)
    try:
        return json.loads(data.decode("utf-8"))
    except ValueError as error:
        raise LookupError_("%s -> not JSON: %s" % (url, error)) from error


def get_text(url: str, headers: dict | None = None) -> str:
    return _read(url, headers, MAX_DOCUMENT_BYTES).decode("utf-8", errors="replace")


def download_sha256(url: str) -> str:
    """The SHA-256 of what `url` serves, hashed while it streams and never written to disk."""
    digest = hashlib.sha256()
    total = 0
    try:
        with _request(url) as response:
            while True:
                chunk = response.read(1024 * 1024)
                if not chunk:
                    break
                total += len(chunk)
                if total > MAX_DOWNLOAD_BYTES:
                    raise LookupError_("%s -> larger than %d bytes; is the template pointing at the right file?"
                                       % (url, MAX_DOWNLOAD_BYTES))
                digest.update(chunk)
    except urllib.error.HTTPError as error:
        raise _http_error(url, error) from error
    except LookupError_:
        raise
    except Exception as error:  # noqa: BLE001 - any transport failure is a lookup failure
        raise LookupError_("%s -> %s" % (url, error)) from error
    return digest.hexdigest()


def github_headers() -> dict:
    headers = {"Accept": "application/vnd.github+json"}
    token = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
    if token:
        headers["Authorization"] = "Bearer %s" % token
    return headers


# --------------------------------------------------------------------------- #
# Resolvers -- one per `# upstream:` kind
# --------------------------------------------------------------------------- #
def newest(tags, track_major: str | None = None, family: str | None = None) -> str:
    """The highest semver-shaped tag, optionally inside one major and one release line."""
    best = ""
    for tag in tags:
        tag_parts = parts(tag)
        if not tag_parts:
            continue
        if family is not None and tag_family(tag) != family:
            continue
        if track_major is not None and str(tag_parts[0]) != str(track_major):
            continue
        if not best or tag_parts > parts(best):
            best = tag
    return best


def qualifiers(track_major: str | None, family: str | None) -> str:
    words = []
    if track_major is not None:
        words.append("within major %s" % track_major)
    if family:
        words.append("in the `%s` release line" % family)
    return (" " + " ".join(words)) if words else ""


def latest_github_release(repo: str, track_major: str | None = None, family: str | None = None) -> str:
    if track_major is None:
        data = get_json("https://api.github.com/repos/%s/releases/latest" % repo, github_headers())
        tag = data.get("tag_name") or ""
        # The fast path answers almost every pin. It is wrong only for a
        # repository that publishes two release lines -- see `tag_family`.
        if family is None or tag_family(tag) == family:
            return tag
    # A pin deliberately held inside a major (GoReleaser 1.x, whose 2.x is a
    # breaking configuration change) needs the newest release WITHIN it, not the
    # newest overall -- otherwise this reports an "update" that is really a
    # migration, every run, forever.
    data = get_json("https://api.github.com/repos/%s/releases?per_page=100" % repo, github_headers())
    best = newest(
        (release.get("tag_name") or "" for release in data
         if not release.get("draft") and not release.get("prerelease")),
        track_major, family)
    if not best:
        raise LookupError_("no release found for %s%s" % (repo, qualifiers(track_major, family)))
    return best


def latest_github_tag(repo: str, track_major: str | None = None, family: str | None = None) -> str:
    data = get_json("https://api.github.com/repos/%s/tags?per_page=100" % repo, github_headers())
    best = newest((tag.get("name") or "" for tag in data), track_major, family)
    if not best:
        raise LookupError_("no semver-shaped tag found for %s%s" % (repo, qualifiers(track_major, family)))
    return best


def latest_gitlab_tag(project: str, track_major: str | None = None, family: str | None = None) -> str:
    encoded = urllib.parse.quote(project, safe="")
    data = get_json("https://gitlab.com/api/v4/projects/%s/repository/tags?per_page=100" % encoded)
    best = newest((tag.get("name") or "" for tag in data), track_major, family)
    if not best:
        raise LookupError_("no semver-shaped tag found for %s%s" % (project, qualifiers(track_major, family)))
    return best


def latest_pypi(package: str, track_major: str | None = None, family: str | None = None) -> str:
    data = get_json("https://pypi.org/pypi/%s/json" % package)
    if track_major is None:
        return data["info"]["version"]
    best = newest(data.get("releases", {}), track_major)
    if not best:
        raise LookupError_("no %s release within major %s" % (package, track_major))
    return best


def latest_npm(package: str, track_major: str | None = None, family: str | None = None) -> str:
    if track_major is None:
        return get_json("https://registry.npmjs.org/%s/latest" % package)["version"]
    data = get_json("https://registry.npmjs.org/%s" % package)
    tag = data.get("dist-tags", {}).get("latest", "")
    return newest(data.get("versions", {}), track_major) or tag


def latest_rubygems(gem: str, track_major: str | None = None, family: str | None = None) -> str:
    return get_json("https://rubygems.org/api/v1/gems/%s.json" % gem)["version"]


def latest_goproxy(module: str, track_major: str | None = None, family: str | None = None) -> str:
    # The proxy lower-cases module paths by escaping capitals as `!x`, so
    # `github.com/CycloneDX/...` must be requested as `github.com/!cyclone!d!x/...`.
    escaped = re.sub(r"([A-Z])", lambda m: "!" + m.group(1).lower(), module)
    return get_json("https://proxy.golang.org/%s/@latest" % escaped)["Version"]


RESOLVERS = {
    "github-release": latest_github_release,
    "github-tag": latest_github_tag,
    "gitlab-tag": latest_gitlab_tag,
    "pypi": latest_pypi,
    "npm": latest_npm,
    "rubygems": latest_rubygems,
    "goproxy": latest_goproxy,
}

# Kinds whose versions are git tags, and so can belong to more than one release line.
TAGGED_KINDS = {"github-release", "github-tag", "gitlab-tag"}


# --------------------------------------------------------------------------- #
# Container registries
# --------------------------------------------------------------------------- #
ACCEPT = ",".join([
    "application/vnd.oci.image.index.v1+json",
    "application/vnd.docker.distribution.manifest.list.v2+json",
    "application/vnd.oci.image.manifest.v1+json",
    "application/vnd.docker.distribution.manifest.v2+json",
])


def split_image(reference: str) -> tuple[str, str, str]:
    """Split `[registry/]repository:tag` into (registry_host, repository, tag)."""
    head = reference.split("@", 1)[0]
    repository, _, tag = head.rpartition(":")
    if not repository:  # no tag at all
        repository, tag = head, "latest"
    first = repository.split("/", 1)[0]
    if "." in first or ":" in first or first == "localhost":
        registry, repository = first, repository.split("/", 1)[1]
    else:
        registry = "registry-1.docker.io"
        if "/" not in repository:
            repository = "library/" + repository
    return registry, repository, tag


def registry_token(registry: str, repository: str) -> str | None:
    if registry == "ghcr.io":
        url = "https://ghcr.io/token?service=ghcr.io&scope=repository:%s:pull" % repository
    elif registry == "registry-1.docker.io":
        url = ("https://auth.docker.io/token?service=registry.docker.io"
               "&scope=repository:%s:pull" % repository)
    else:
        return None  # mcr.microsoft.com and friends serve anonymously
    return get_json(url).get("token")


def image_digest(reference: str) -> str:
    registry, repository, tag = split_image(reference)
    headers = {"Accept": ACCEPT}
    token = registry_token(registry, repository)
    if token:
        headers["Authorization"] = "Bearer %s" % token
    url = "https://%s/v2/%s/manifests/%s" % (registry, repository, tag)
    try:
        with _request(url, headers, method="HEAD") as response:
            digest = response.headers.get("Docker-Content-Digest")
    except urllib.error.HTTPError as error:
        raise LookupError_("%s -> HTTP %s" % (reference, error.code)) from error
    except Exception as error:  # noqa: BLE001
        raise LookupError_("%s -> %s" % (reference, error)) from error
    if not digest:
        raise LookupError_("%s -> registry returned no Docker-Content-Digest" % reference)
    return digest


# --------------------------------------------------------------------------- #
# Discovery
# --------------------------------------------------------------------------- #
# `.pipelines` is where the workflow used to check THIS repository out inside
# the one being scanned, and where a consumer running it by hand may still put
# it. Without the skip, a consumer's report would list this library's pins as if
# they were the consumer's own -- and this repository's own run would count every
# pin twice.
SKIP_DIRS = {".git", "node_modules", "build", ".terraform", ".pipelines"}
MANIFEST = Path("global") / "scripts" / "shared" / "pinned-versions.sh"

UPSTREAM = re.compile(r"^#\s*upstream:\s*(?P<kind>[a-z-]+)\s+(?P<coord>\S+)(?P<opts>.*)$")
CHECKSUMS = re.compile(r"^#\s*checksums:\s*(?P<url>\S+)\s*$")
ASSET = re.compile(r"^#\s*asset:\s*(?P<url>\S+)\s*$")
PIN = re.compile(r'^(?P<name>[A-Z0-9_]+)_PINNED_VERSION="(?P<value>[^"]*)"')
SPEC = re.compile(r'^(?P<name>[A-Z0-9_]+)_SPEC="\$\{[A-Z0-9_]+:-(?P<value>[^}"]*)\}"')
# Any `NAME="<64 hex>"`; that the name carries `_SHA256` is checked in code. Spelt
# into the pattern (`[A-Z0-9_]+_SHA256...`), the name's two runs of the same
# character class made the engine backtrack over every split of the name.
DIGEST = re.compile(r'^(?P<var>[A-Z0-9_]+)="(?P<value>[0-9a-f]{64})"\s*$')
USES = re.compile(
    r"^\s*(?:-\s*)?uses:\s*'(?P<repo>[^'@]+)@(?P<sha>[0-9a-f]{40})'\s*#\s*(?P<version>\S+)")
IMAGE = re.compile(r"^\s*(?:-\s*)?image:\s*'(?P<ref>[^']+@sha256:[0-9a-f]+)'")
FROM = re.compile(r"^FROM\s+(?P<ref>\S+@sha256:[0-9a-f]+)")


def walk(root: Path, suffixes=None, names=None):
    # Pruned while walking rather than filtered afterwards: `.git` and
    # `node_modules` hold more files than everything else put together, and
    # nothing in them is a pin.
    for directory, subdirectories, files in os.walk(root):
        subdirectories[:] = sorted(name for name in subdirectories if name not in SKIP_DIRS)
        for name in sorted(files):
            path = Path(directory) / name
            if suffixes and path.suffix in suffixes:
                yield path
            elif names and name.startswith(tuple(names)):
                yield path


class Workspace:
    """The scanned repository's pinned files, read once and edited in memory.

    Discovery and `--apply` read the same files, so they share one cache: a pin
    is rewritten in exactly the text it was discovered in, every file is written
    back at most once, and only after every edit to it has succeeded.

    Files are read and written with `newline=""`, so a CRLF file stays CRLF and
    the only bytes that change are the ones an edit names. Two kinds of file are
    scanned but never written. One that is not valid UTF-8, because rewriting it
    through a replacement character would corrupt the parts nobody asked to
    touch. And a symlink, because writing through one edits whatever it points
    at -- possibly outside the repository; the file it names inside the tree is
    reached under its own path anyway.
    """

    def __init__(self, root: Path) -> None:
        self.root = root
        self.yaml = list(walk(root, suffixes={".yaml", ".yml"}))
        self.dockerfiles = list(walk(root, names={"Dockerfile"}))
        self._original: dict[Path, str | None] = {}
        self._current: dict[Path, str] = {}
        self._unwritable: set[Path] = set()

    def text(self, path: Path) -> str:
        if path not in self._current:
            if path.is_symlink():
                self._unwritable.add(path)
            try:
                with open(path, encoding="utf-8", newline="") as handle:
                    original = handle.read()
            except FileNotFoundError:
                original = None
            except UnicodeDecodeError:
                with open(path, encoding="utf-8", errors="replace", newline="") as handle:
                    original = handle.read()
                self._unwritable.add(path)
            self._original[path] = original
            self._current[path] = original or ""
        return self._current[path]

    def set(self, path: Path, text: str) -> bool:
        self.text(path)
        if path in self._unwritable:
            return False
        self._current[path] = text
        return True

    def changed(self) -> list[Path]:
        def differs(path: Path) -> bool:
            original = self._original.get(path)
            return self._current[path] != original if original is not None else self._current[path] != ""

        return sorted(path for path in self._current if differs(path))

    def write(self) -> list[str]:
        written = []
        for path in self.changed():
            path.parent.mkdir(parents=True, exist_ok=True)
            with open(path, "w", encoding="utf-8", newline="") as handle:
                handle.write(self._current[path])
            written.append(str(path.relative_to(self.root)))
        return written


def spec_version(value: str) -> str:
    """Pull the version out of a package spec (`pdm==2.28.1`, `knip@6.32.2`)."""
    for separator in ("==", "@", ":"):
        if separator in value:
            return value.rsplit(separator, 1)[1]
    return value


def discover_manifest(root: Path) -> list[dict]:
    """Every pin in `pinned-versions.sh`, with the annotations that say how to check and rewrite it.

    Three annotations are read, each a comment directly above what it describes:

      # upstream:  <kind> <coordinate> [track=<major>]   above a pin -- where releases come from
      # checksums: <url with {version}>                  above a pin -- the publisher's manifest
      # asset:     <url with {version}>                  above a digest -- the file it is of

    A digest belongs to the pin whose name it extends (`GITLEAKS_SHA256_X64` to
    `GITLEAKS`), so its place in the file does not have to be guessed from. The
    two pin annotations may come in either order: a `# checksums:` line silently
    dropped for sitting above `# upstream:` would take its cross-check with it.
    """
    manifest = root / MANIFEST
    # Absent in a CONSUMER's repository, which has no pinned-versions.sh of its
    # own. The action and image scans below are generic, so the check still does
    # something useful there rather than failing on a file it had no reason to
    # expect.
    if not manifest.is_file():
        return []
    parser = ManifestParser()
    for raw in manifest.read_text(encoding="utf-8").splitlines():
        parser.feed(raw)
    return parser.entries


class ManifestParser:
    """`pinned-versions.sh`, one line at a time: each annotation waits for the line it describes."""

    def __init__(self) -> None:
        self.entries: list[dict] = []
        self.upstream: dict | None = None
        self.checksums: str | None = None
        self.asset: str | None = None

    def feed(self, raw: str) -> None:
        stripped = raw.strip()
        if self.annotation(stripped):
            return
        digest = DIGEST.match(raw)
        if digest and "_SHA256" in digest.group("var"):
            self.add_digest(digest.group("var"), digest.group("value"))
            return
        pin = PIN.match(raw)
        spec = SPEC.match(raw)
        if pin or spec:
            self.add_pin(pin or spec, spec is not None)
        elif stripped and not stripped.startswith("#"):
            # Any other code line ends whatever was waiting: an annotation
            # describes the line directly beneath its comment block, never one
            # further down.
            self.upstream = self.checksums = self.asset = None

    def annotation(self, stripped: str) -> bool:
        upstream = UPSTREAM.match(stripped)
        if upstream:
            options = {key: value for key, _, value in (word.partition("=") for word in upstream.group("opts").split())
                       if value}
            self.upstream = {"kind": upstream.group("kind"), "coord": upstream.group("coord"),
                             "track_major": options.get("track")}
            return True
        checksums = CHECKSUMS.match(stripped)
        if checksums:
            self.checksums = checksums.group("url")
            return True
        asset = ASSET.match(stripped)
        if asset:
            self.asset = asset.group("url")
            return True
        return False

    def add_digest(self, var: str, value: str) -> None:
        owners = [entry for entry in self.entries if var.startswith(entry["name"] + "_SHA256")]
        if owners:
            owner = max(owners, key=lambda entry: len(entry["name"]))
            owner["digests"].append({"var": var, "value": value, "asset": self.asset})
        self.asset = None

    def add_pin(self, match: re.Match, is_spec: bool) -> None:
        value, name = match.group("value"), match.group("name")
        entry = {
            "kind": "unannotated",
            "name": name,
            "var": "%s_%s" % (name, "SPEC" if is_spec else "PINNED_VERSION"),
            "style": "spec" if is_spec else "pin",
            "spec_value": value if is_spec else None,
            "current": spec_version(value) if is_spec else value,
            "checksums": None,
            "digests": [],
        }
        if self.upstream is not None:
            entry.update(self.upstream)
            entry["checksums"] = self.checksums
        self.entries.append(entry)
        self.upstream = self.checksums = None


def manifest_values(manifest: list[dict]) -> dict[str, str]:
    """Every manifest variable an inline copy can mirror -> its value."""
    values: dict[str, str] = {}
    for entry in manifest:
        values[entry["var"]] = entry["current"]
        for digest in entry["digests"]:
            values[digest["var"]] = digest["value"]
    return values


def discover_actions(ws: Workspace) -> dict[str, str]:
    """Distinct third-party action repositories -> the version comment recorded.

    Sub-path actions (`github/codeql-action/init`) collapse onto their owning
    repository, which is what carries the release.
    """
    found: dict[str, str] = {}
    for path in ws.yaml:
        for line in ws.text(path).splitlines():
            match = USES.match(line)
            if not match:
                continue
            repo = match.group("repo")
            if repo.startswith("rios0rios0/"):
                continue
            owner_repo = "/".join(repo.split("/")[:2])
            version = match.group("version")
            if owner_repo not in found or is_newer(found[owner_repo], version):
                found[owner_repo] = version
    return found


def discover_images(ws: Workspace) -> dict[str, str]:
    found: dict[str, str] = {}
    for path in ws.yaml:
        for line in ws.text(path).splitlines():
            match = IMAGE.match(line)
            if match:
                reference = match.group("ref")
                found[reference] = reference.split("@", 1)[1]
    for path in ws.dockerfiles:
        for line in ws.text(path).splitlines():
            match = FROM.match(line)
            if match:
                reference = match.group("ref")
                found[reference] = reference.split("@", 1)[1]
    return found


# Values written a second time in a template, because that template has no
# `SCRIPTS_DIR` to source the manifest from. A copy is not a problem; a copy
# that has drifted is, and it drifts silently -- two of them already had: the
# Azure DevOps ProGuard job was still on 7.6.1 and the Azure Terragrunt abstract
# on 1.1.3, a bump after the manifest had moved on, and nothing reported it.
#
# Each row is a manifest VARIABLE and a pattern whose one group is a copy of its
# value. The same table drives drift detection and `--apply`, so a copy the
# check knows about is a copy the bump rewrites, and the two cannot disagree.
INLINE_COPIES = [
    ("PDM_SPEC", r'pip install[^"\n]*"pdm==([0-9][^"]*)"'),
    ("VULTURE_SPEC", r'pip install[^"\n]*"vulture==([0-9][^"]*)"'),
    ("KNIP_SPEC", r"npx --yes[^\n]*knip@([0-9][^\s'\"]*)"),
    ("GOVULNCHECK_PINNED_VERSION", r"go install golang\.org/x/vuln/cmd/govulncheck@v?([0-9][^\s'\"]*)"),
    ("BUNDLER_AUDIT_SPEC", r"gem install bundler-audit -v ([0-9][^\s'\"]*)"),
    ("GORELEASER_PINNED_VERSION", r'GORELEASER_VERSION:\s*"([0-9][^"]*)"'),
    ("PROGUARD_PINNED_VERSION", r"Guardsquare/proguard/releases/download/v([0-9][^/\"'\s]*)/"),
    ("PROGUARD_PINNED_VERSION", r"proguard-([0-9][0-9.]*[0-9])(?=\.tar\.gz|/lib/)"),
    ("PROGUARD_SHA256", r'"([0-9a-f]{64})  /tmp/proguard\.tar\.gz"'),
    ("TERRAGRUNT_PINNED_VERSION", r'TERRAGRUNT_VERSION="([0-9][^"]*)"'),
    ("TERRAGRUNT_SHA256_AMD64", r'TERRAGRUNT_SHA256="([0-9a-f]{64})"'),
    ("STOML_PINNED_VERSION", r'STOML_VERSION="([0-9][^"]*)"'),
    ("STOML_SHA256_AMD64", r'STOML_SHA256="([0-9a-f]{64})"'),
]


def is_digest_var(var: str) -> bool:
    return "_SHA256" in var


def inline_files(ws: Workspace) -> list[Path]:
    return ws.yaml + ws.dockerfiles


def same_value(var: str, found: str, want: str) -> bool:
    if is_digest_var(var):
        return found.lower() == want.lower()
    return normalise(found) == normalise(want)


def discover_inline(ws: Workspace, manifest: list[dict]) -> list[dict]:
    expected = manifest_values(manifest)
    findings = []
    for var, pattern in INLINE_COPIES:
        want = expected.get(var)
        if want is None:
            continue
        compiled = re.compile(pattern)
        for path in inline_files(ws):
            for found in compiled.findall(ws.text(path)):
                if not same_value(var, found, want):
                    findings.append({
                        "name": var,
                        "file": str(path.relative_to(ws.root)),
                        "inline": found,
                        "manifest": want,
                    })
    return findings


# --------------------------------------------------------------------------- #
# Checking
# --------------------------------------------------------------------------- #
def ask_upstream(task: dict, fixture: dict | None) -> str:
    """Upstream's newest release (or an image tag's digest), live or from the offline fixture."""
    if fixture is not None:
        key = "%s:%s" % (task["kind"], task["coord"])
        if key not in fixture:
            raise LookupError_("no fixture entry for %s" % key)
        return fixture[key]
    if task["kind"] == "image":
        return image_digest(task["coord"])
    resolver = RESOLVERS.get(task["kind"])
    if resolver is None:
        raise LookupError_("unknown upstream kind '%s'" % task["kind"])
    return resolver(task["coord"], task.get("track_major"), task.get("family"))


def within_bounds(task: dict, latest: str) -> str:
    """`latest`, or the pin as it is when `latest` lies outside what the pin follows.

    A pin deliberately held inside a major reports nothing when upstream's newest
    release is OUTSIDE that major -- moving from GoReleaser 1.x to 2.x is a
    migration, not an update, and reporting it every run is how a check gets
    muted. Applied here rather than only inside the GitHub resolver so it holds
    for every upstream kind, and so the offline fixture path behaves exactly like
    the live one.

    Likewise a release from ANOTHER line of the same repository is never an
    update -- see `tag_family`. The live resolvers never return one; this keeps
    an answer that did (a fixture, a future resolver) from being compared across
    lines, where `codeql-bundle-v2.26.4` would read as older than the action's
    `v4.37.7`.
    """
    if task["kind"] == "image":
        return latest
    track = task.get("track_major")
    if track is not None:
        latest_parts = parts(latest)
        if not latest_parts or str(latest_parts[0]) != str(track):
            return task["current"]
    family = task.get("family")
    if family is not None and task["kind"] in TAGGED_KINDS and tag_family(latest) != family:
        return task["current"]
    return latest


def resolve(task: dict, fixture: dict | None) -> dict:
    try:
        latest = within_bounds(task, ask_upstream(task, fixture))
        task["latest"] = latest
        task["outdated"] = (
            latest != task["current"] if task["kind"] == "image"
            else is_newer(task["current"], latest)
        )
    except LookupError_ as error:
        task["error"] = str(error)
    return task


def load_ignores(root: Path) -> list[str]:
    """Labels this repository has decided not to track, from `.dependency-updates.json`.

    Deliberately empty by default. It exists for genuinely ROLLING references --
    `alpine:edge` is rebuilt almost daily, so it would report an update on nearly
    every run, and a check that is always red is a check people stop reading --
    and for a dependency somebody has decided to stay on for good. Silencing one
    of those is a decision worth writing down in a file; silencing them by
    default would hide the ordinary stale pins this tool exists to find.
    """
    config = root / ".dependency-updates.json"
    if not config.is_file():
        return []
    try:
        return list(json.loads(config.read_text(encoding="utf-8")).get("ignore", []))
    except (ValueError, OSError):
        print("WARNING: could not read %s; ignoring nothing" % config, file=sys.stderr)
        return []


def build_tasks(ws: Workspace) -> tuple[list[dict], list[dict], list[dict], list[dict]]:
    root = ws.root
    manifest = discover_manifest(root)
    tasks: list[dict] = []
    unannotated: list[dict] = []

    for entry in manifest:
        # A digest nothing can re-derive is a pin `--apply` can never bump, and
        # it would go on reading as covered: the same slow loss of coverage an
        # unannotated pin is, so it is reported the same way.
        for digest in entry["digests"]:
            if not digest["asset"]:
                unannotated.append({"kind": "unannotated", "missing": "asset",
                                    "name": digest["var"], "current": digest["value"][:12]})
        if entry["kind"] == "unannotated":
            unannotated.append({"kind": "unannotated", "missing": "upstream",
                                "name": entry["name"], "current": entry["current"]})
            continue
        if entry["kind"] == "none":
            continue
        tasks.append({
            "group": "manifest",
            "label": entry["name"],
            "kind": entry["kind"],
            "coord": entry["coord"],
            "track_major": entry.get("track_major"),
            "family": tag_family(entry["current"]) if entry["kind"] in TAGGED_KINDS else None,
            "current": entry["current"],
            "entry": entry,
        })

    for repo, version in sorted(discover_actions(ws).items()):
        tasks.append({
            "group": "action",
            "label": repo,
            "kind": "github-release",
            "coord": repo,
            "track_major": None,
            "family": tag_family(version),
            "current": version,
        })

    for reference, digest in sorted(discover_images(ws).items()):
        tasks.append({
            "group": "image",
            "label": reference.split("@", 1)[0],
            "kind": "image",
            "coord": reference,
            "track_major": None,
            "current": digest,
        })

    ignores = load_ignores(root)
    if ignores:
        tasks = [task for task in tasks
                 if not any(fnmatch.fnmatch(task["label"], pattern) for pattern in ignores)]

    return tasks, unannotated, discover_inline(ws, manifest), manifest


# --------------------------------------------------------------------------- #
# Upstream lookups for `--apply`
# --------------------------------------------------------------------------- #
SHA1 = re.compile(r"^[0-9a-f]{40}$")
SHA256_HEX = re.compile(r"^[0-9a-f]{64}$")
SHA256_PREFIX = "sha256:"
IMAGE_DIGEST = re.compile(r"^sha256:[0-9a-f]{64}$")
# What an upstream may call a release before it is written into a SOURCED shell
# file, a YAML comment and a Markdown table. Deliberately narrow: no quote, `$`,
# backtick, space, `|`, `<` or newline can reach any of the three, so a hostile
# or merely odd tag name is refused instead of executed or rendered.
SAFE_VERSION = re.compile(r"^[0-9A-Za-z][0-9A-Za-z._+-]{0,127}$")
SAFE_TAG = re.compile(r"^[0-9A-Za-z][0-9A-Za-z._+/-]{0,127}$")
RELEASE_ASSET = re.compile(
    r"^https://github\.com/(?P<repo>[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)"
    r"/releases/download/(?P<tag>[^/]+)/(?P<asset>[^/?#]+)$")
TRAILER = "Dependency-Updates-Fingerprint:"
MARKER = "dependency-updates-fingerprint:"


class Lookups:
    """The questions `--apply` asks upstream, answered live or from the offline fixture.

    The fixture answers the same three transport questions the live path asks --
    a JSON document, a text document, the SHA-256 of a download -- keyed by the
    URL that would have been fetched (`GET <url>`, `SHA256 <url>`; `null` is a
    404). Everything above the transport therefore runs the same code offline as
    it does against GitHub: the URL construction, dereferencing an annotated
    tag, falling back to a download when GitHub recorded no digest, and parsing
    a checksum manifest.
    """

    def __init__(self, fixture: dict | None) -> None:
        self.fixture = fixture
        self._cache: dict[str, object] = {}

    def _answer(self, verb: str, url: str):
        key = "%s %s" % (verb, url)
        if key not in self.fixture:
            raise LookupError_("no fixture entry for %s" % key)
        if self.fixture[key] is None:
            raise NotFound("%s -> HTTP 404" % url)
        return self.fixture[key]

    def json(self, url: str, headers: dict | None = None):
        if self.fixture is not None:
            return self._answer("GET", url)
        if url not in self._cache:
            self._cache[url] = get_json(url, headers)
        return self._cache[url]

    def text(self, url: str) -> str:
        if self.fixture is not None:
            return str(self._answer("GET", url))
        return get_text(url)

    def sha256(self, url: str) -> str:
        if self.fixture is not None:
            return str(self._answer("SHA256", url))
        return download_sha256(url)


def tag_commit(lookups: Lookups, repo: str, tag: str) -> str:
    """The commit a release tag points at, dereferencing an annotated tag.

    An annotated tag's ref names a TAG OBJECT, not a commit, and pinning that
    object's SHA would read correctly and resolve to nothing a runner can check
    out. The chain is followed to the commit.
    """
    target = (lookups.json("https://api.github.com/repos/%s/git/ref/tags/%s"
                           % (repo, urllib.parse.quote(tag, safe="/")), github_headers()) or {}).get("object") or {}
    for _ in range(5):
        kind, sha = target.get("type"), target.get("sha") or ""
        if kind == "commit":
            if not SHA1.match(sha):
                raise LookupError_("%s@%s -> %r is not a commit SHA" % (repo, tag, sha))
            return sha
        if kind != "tag" or not SHA1.match(sha):
            raise LookupError_("%s@%s points at %s, not a commit" % (repo, tag, kind or "nothing"))
        target = (lookups.json("https://api.github.com/repos/%s/git/tags/%s" % (repo, sha),
                               github_headers()) or {}).get("object") or {}
    raise LookupError_("%s@%s -> tag chain too deep to dereference" % (repo, tag))


def asset_digest(lookups: Lookups, url: str) -> tuple[str, str]:
    """The SHA-256 of the file at `url`, and where that answer came from.

    For a GitHub release asset this is the digest GitHub recorded when the asset
    was uploaded, which needs no download -- the CodeQL bundle alone is a
    gigabyte. A release published before GitHub recorded digests has none, and
    then, like any other URL, the file is downloaded and hashed.
    """
    release = RELEASE_ASSET.match(url)
    if release:
        repo = release.group("repo")
        tag = urllib.parse.unquote(release.group("tag"))
        name = urllib.parse.unquote(release.group("asset"))
        data = lookups.json("https://api.github.com/repos/%s/releases/tags/%s"
                            % (repo, urllib.parse.quote(tag, safe="")), github_headers()) or {}
        assets = {asset.get("name"): asset for asset in data.get("assets") or []}
        if name not in assets:
            raise NotFound("release %s of %s has no asset named %s" % (tag, repo, name))
        recorded = (assets[name].get("digest") or "").removeprefix(SHA256_PREFIX)
        if SHA256_HEX.match(recorded):
            return recorded, "GitHub's recorded digest of the release asset"
    computed = lookups.sha256(url).lower()
    if not SHA256_HEX.match(computed):
        raise LookupError_("%s -> %r is not a SHA-256" % (url, computed))
    return computed, "SHA-256 of the downloaded asset"


# Matched against a STRIPPED line, so the name runs to the end with no trailing
# whitespace to give back -- the lazy `\S.*?\s*$` this replaced backtracked on
# every long line it did not match.
GNU_SUM = re.compile(r"^(?P<hex>[0-9a-fA-F]{64})\s+\*?(?P<name>[^\s*]\S*)$")
BSD_SUM = re.compile(r"^SHA-?256\s*\((?P<name>[^)]+)\)\s*=\s*(?P<hex>[0-9a-fA-F]{64})\s*$")


def published_checksum(text: str, asset: str) -> str | None:
    """The SHA-256 a checksum manifest publishes for `asset`, from either common format.

    GNU (`<hex>  <name>` or `<hex> *<name>`) is what nearly every publisher here
    ships. BSD (`SHA256 (<name>) = <hex>`) is yq's `checksums-bsd`, whose other
    lines carry thirty unrelated algorithms -- which is why the algorithm is
    matched whole, so a `SHA3-256` line can never be read as SHA-256. A file
    holding one bare digest is a per-asset checksum and answers for that asset.
    """
    for line in text.splitlines():
        for pattern in (GNU_SUM, BSD_SUM):
            match = pattern.match(line.strip())
            if match and match.group("name").rsplit("/", 1)[-1] == asset:
                return match.group("hex").lower()
    bare = text.strip().lower()
    if SHA256_HEX.match(bare):
        return bare
    return None


def render(template: str, version: str) -> str:
    return template.replace("{version}", version)


class Refused(Exception):
    """An update that is real but cannot be applied safely; it needs a person."""


def require_annotations(entry: dict, new: str) -> None:
    missing = [digest["var"] for digest in entry["digests"] if not digest["asset"]]
    if missing:
        raise Refused("%s %s no `# asset:` annotation, so %s cannot be re-derived for %s"
                      % (", ".join(missing), "has" if len(missing) == 1 else "have",
                         "its digest" if len(missing) == 1 else "their digests", new))


def derive_digest(lookups: Lookups, digest: dict, current: str, new: str) -> dict:
    """The SHA-256 of one digest's asset at `new` -- once its template has proven itself at `current`."""
    today = render(digest["asset"], current)
    proposed = render(digest["asset"], new)
    if today == proposed:
        raise Refused("the `# asset:` template for %s has no `{version}`, so it cannot locate %s"
                      % (digest["var"], new))
    # The template is proven against the digest the installer verifies TODAY
    # before it is trusted to locate the file it will verify next.
    try:
        reproduced, _ = asset_digest(lookups, today)
    except NotFound as error:
        raise Refused("the `# asset:` template for %s does not locate the pinned %s (%s); fix the template"
                      % (digest["var"], current, error)) from error
    if reproduced != digest["value"]:
        raise Refused("the `# asset:` template for %s locates a file whose SHA-256 is not the committed one "
                      "for %s, so it is not the asset the installer verifies and cannot be trusted for %s"
                      % (digest["var"], current, new))
    try:
        value, source = asset_digest(lookups, proposed)
    except NotFound as error:
        raise Refused("%s; if the release renamed its assets, the installer and the `# asset:` template "
                      "both have to follow" % error) from error
    return {"var": digest["var"], "old": digest["value"], "new": value, "source": source, "url": proposed}


def cross_check(lookups: Lookups, manifest_url: str, new: str, digests: list[dict]) -> None:
    """Every new digest must be the one the publisher's checksum manifest lists for its asset."""
    try:
        text = lookups.text(manifest_url)
    except NotFound as error:
        raise Refused("the checksum manifest %s does not exist for %s" % (manifest_url, new)) from error
    for digest in digests:
        asset = digest["url"].rsplit("/", 1)[-1]
        published = published_checksum(text, asset)
        if published is None:
            raise Refused("%s publishes no SHA-256 for %s" % (manifest_url, asset))
        if published != digest["new"]:
            raise Refused("%s publishes %s for %s, but the asset itself is %s. A release that disagrees "
                          "with its own checksums is what verification exists to catch; look before "
                          "trusting either" % (manifest_url, published, asset, digest["new"]))
        digest["source"] += ", matching `%s`" % manifest_url.rsplit("/", 1)[-1]


def prepare_manifest(task: dict, lookups: Lookups) -> dict:
    """Resolve the new version's digests, or refuse to touch the pin at all."""
    entry = task["entry"]
    new = restyle(task["current"], task["latest"])
    if not SAFE_VERSION.match(new):
        raise Refused("upstream named the release %r, which is not safe to write into a sourced shell file"
                      % task["latest"])
    require_annotations(entry, new)
    digests = [derive_digest(lookups, digest, task["current"], new) for digest in entry["digests"]]
    if entry.get("checksums") and digests:
        cross_check(lookups, render(entry["checksums"], new), new, digests)
    return {"new": new, "digests": digests}


def prepare_action(task: dict, lookups: Lookups) -> dict:
    tag = task["latest"]
    if not SAFE_TAG.match(tag):
        raise Refused("upstream named the release %r, which is not safe to write into a workflow" % tag)
    return {"new": tag, "sha": tag_commit(lookups, task["coord"], tag)}


def prepare_image(task: dict) -> dict:
    if not IMAGE_DIGEST.match(task["latest"]):
        raise Refused("the registry answered %r, which is not an image digest" % task["latest"])
    return {"new": task["latest"]}


def prepare(task: dict, lookups: Lookups) -> dict:
    """Everything `--apply` needs from upstream for one outdated pin, before any file is touched."""
    try:
        if task["group"] == "manifest":
            task["apply"] = prepare_manifest(task, lookups)
        elif task["group"] == "action":
            task["apply"] = prepare_action(task, lookups)
        else:
            task["apply"] = prepare_image(task)
    except Refused as reason:
        task["refused"] = str(reason)
    except NotFound as error:
        task["refused"] = str(error)
    except LookupError_ as error:
        task["error"] = str(error)
    return task


# --------------------------------------------------------------------------- #
# Applying
# --------------------------------------------------------------------------- #
def repin(text: str, pattern: re.Pattern, plan: dict) -> tuple[str, int]:
    """`text` with every `uses:` the pattern matches re-pinned to `plan`, and how many changed."""
    changes = 0

    def replace(match: re.Match) -> str:
        nonlocal changes
        if match.group("sha") == plan["sha"] and match.group("version") == plan["new"]:
            return match.group(0)
        changes += 1
        return match.group("head") + plan["sha"] + match.group("mid") + plan["new"]

    return pattern.sub(replace, text), changes


def write_action(ws: Workspace, task: dict) -> int:
    """Re-pin every `uses:` of the action, sub-path actions included, to the new commit."""
    pattern = re.compile(
        r"(?P<head>^[ \t]*(?:-[ \t]*)?uses:[ \t]*'%s(?:/[^'@\s]*)?@)(?P<sha>[0-9a-f]{40})"
        r"(?P<mid>'[ \t]*#[ \t]*)(?P<version>\S+)" % re.escape(task["coord"]), re.MULTILINE)
    rewritten = 0
    for path in ws.yaml:
        text, changes = repin(ws.text(path), pattern, task["apply"])
        if changes and ws.set(path, text):
            rewritten += changes
    return rewritten


def write_image(ws: Workspace, task: dict) -> int:
    old = task["coord"]
    new = old.split("@", 1)[0] + "@" + task["apply"]["new"]
    # Bounded on both sides, so `python:3.13-slim@sha256:...` is never rewritten
    # inside a longer reference to a different repository that happens to end
    # the same way -- a mirror of the same image, say.
    pattern = re.compile(r"(?<![A-Za-z0-9._/:-])%s(?![0-9a-f])" % re.escape(old))
    rewritten = 0
    for path in inline_files(ws):
        text, count = pattern.subn(lambda match: new, ws.text(path))
        if count and ws.set(path, text):
            rewritten += count
    return rewritten


def write_manifest(ws: Workspace, task: dict) -> int:
    """Rewrite the pin and every digest of it in one edit, or nothing at all."""
    entry, plan = task["entry"], task["apply"]
    path = ws.root / MANIFEST
    text = ws.text(path)
    if entry["style"] == "pin":
        line = r'^(%s=")%s(")(?=\r?$)' % (re.escape(entry["var"]), re.escape(task["current"]))
        value = plan["new"]
    else:
        spec = entry["spec_value"]
        line = r'^(%s="\$\{[A-Z0-9_]+:-)%s(\}")(?=\r?$)' % (re.escape(entry["var"]), re.escape(spec))
        value = spec[: len(spec) - len(task["current"])] + plan["new"]
    edits = [(entry["var"], line, value)]
    for digest in plan["digests"]:
        edits.append((digest["var"], r'^(%s=")%s(")(?=\r?$)' % (re.escape(digest["var"]), re.escape(digest["old"])),
                      digest["new"]))
    for var, pattern, replacement in edits:
        text, count = re.subn(pattern, lambda match, r=replacement: match.group(1) + r + match.group(2), text,
                              flags=re.MULTILINE)
        if count != 1:
            raise Refused("%s: expected exactly one `%s` line to rewrite, found %d" % (MANIFEST, var, count))
    if not ws.set(path, text):
        raise Refused("%s cannot be rewritten safely (a symlink, or not valid UTF-8)" % MANIFEST)
    return len(edits)


def align_copies(text: str, compiled: re.Pattern, var: str, want: str, before: str,
                 relative: str) -> tuple[str, list[dict]]:
    """`text` with every copy of `var` the pattern finds set to `want`, and a record of each change."""
    changed: list[dict] = []

    def replace(match: re.Match) -> str:
        found = match.group(1)
        if same_value(var, found, want):
            return match.group(0)
        value = want if is_digest_var(var) else restyle(found, want)
        changed.append({"var": var, "file": relative, "from": found, "to": value,
                        "drifted": not same_value(var, found, before)})
        start, end = match.start(1) - match.start(0), match.end(1) - match.start(0)
        return match.group(0)[:start] + value + match.group(0)[end:]

    return compiled.sub(replace, text), changed


def write_inline(ws: Workspace, targets: dict[str, str], before: dict[str, str]) -> list[dict]:
    """Bring every inline copy to the value its manifest variable now holds.

    `targets` holds the value after this run's bumps, `before` the value the
    manifest had when the run started -- so a copy that disagreed with `before`
    was already out of step, and is reported as such rather than as part of a
    bump it had nothing to do with.
    """
    fixes = []
    for var, pattern in INLINE_COPIES:
        want = targets.get(var)
        if want is None:
            continue
        compiled = re.compile(pattern)
        for path in inline_files(ws):
            text, changed = align_copies(ws.text(path), compiled, var, want, before.get(var, want),
                                         str(path.relative_to(ws.root)))
            if changed and ws.set(path, text):
                fixes.extend(changed)
    return fixes


def apply_updates(ws: Workspace, results: list[dict], manifest: list[dict], lookups: Lookups,
                  jobs: int) -> tuple[list[dict], list[dict]]:
    outdated = [task for task in results if task.get("outdated")]
    with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, jobs)) as pool:
        prepared = list(pool.map(lambda task: prepare(task, lookups), outdated))

    before = manifest_values(manifest)
    targets = dict(before)
    for task in prepared:
        if "apply" not in task or task.get("refused") or task.get("error"):
            continue
        try:
            if task["group"] == "manifest":
                write_manifest(ws, task)
                targets[task["entry"]["var"]] = task["apply"]["new"]
                for digest in task["apply"]["digests"]:
                    targets[digest["var"]] = digest["new"]
                task["rewritten"] = 1
            elif task["group"] == "action":
                task["rewritten"] = write_action(ws, task)
            else:
                task["rewritten"] = write_image(ws, task)
        except Refused as reason:
            task["refused"] = str(reason)
            continue
        if not task["rewritten"]:
            task["refused"] = "no line in the repository matched it, so there was nothing to rewrite"
            continue
        task["applied"] = True
    return prepared, write_inline(ws, targets, before)


# --------------------------------------------------------------------------- #
# The pull request
# --------------------------------------------------------------------------- #
def fingerprint(applied: list[dict], fixes: list[dict]) -> str:
    """One hash for one SET of proposed changes.

    It is what lets a closed pull request mean "not this": the workflow does not
    propose a set it finds in a declined pull request, and any newer release
    changes the set -- and with it the hash. The proposed commit SHA and every
    new digest are part of it, so a re-pointed tag or re-uploaded asset is
    proposed again rather than hidden behind an earlier "no".
    """
    lines = []
    for task in applied:
        plan = task["apply"]
        lines.append("|".join([task["group"], task["label"], plan["new"], plan.get("sha", "")]
                              + [digest["new"] for digest in plan.get("digests", [])]))
    for fix in fixes:
        lines.append("|".join(["inline", fix["file"], fix["var"], fix["to"]]))
    return hashlib.sha256("\n".join(sorted(lines)).encode("utf-8")).hexdigest()


# Where a person reads what changed in a release, by `# upstream:` kind.
RELEASE_PAGES = {
    "github-release": "https://github.com/{coord}/releases/tag/{version}",
    "github-tag": "https://github.com/{coord}/releases/tag/{version}",
    "gitlab-tag": "https://gitlab.com/{coord}/-/tags/{version}",
    "pypi": "https://pypi.org/project/{coord}/{version}/",
    "npm": "https://www.npmjs.com/package/{coord}/v/{version}",
    "rubygems": "https://rubygems.org/gems/{coord}/versions/{version}",
    "goproxy": "https://pkg.go.dev/{coord}@{version}",
}


def release_link(task: dict) -> str | None:
    page = RELEASE_PAGES.get(task["kind"]) if task["group"] != "image" else None
    return page.format(coord=task["coord"], version=task.get("latest", "")) if page else None


def md_safe(value: str, limit: int = 300) -> str:
    """An UPSTREAM-supplied string, made inert for a Markdown page.

    Release names reach the job summary and the pull request body, and both are
    rendered as Markdown -- so a tag or a refusal message quoting one could
    otherwise carry a link, an image or a broken table into a page a person is
    reading in order to decide what to trust. Values that were validated before
    being applied never need this; anything shown BECAUSE it was refused does.

    Only what can leave a code span or a table cell, open a link, or start HTML
    is replaced. Asset names are full of underscores, and mangling those would
    make a refusal unreadable without making it any safer.
    """
    cleaned = re.sub(r"[`|<>\[\]\r\n]", "?", str(value))
    return cleaned if len(cleaned) <= limit else cleaned[:limit] + "..."


def short_digest(digest: str) -> str:
    return digest.replace(SHA256_PREFIX, "")[:12]


def shown(task: dict, value: str) -> str:
    """A pinned value as a person reads it: digests shortened, versions whole."""
    return short_digest(value) if task["group"] == "image" else value


def plural(count: int, singular: str, many: str | None = None) -> str:
    return "%d %s" % (count, singular if count == 1 else (many or singular + "s"))


def copies(count: int) -> str:
    return plural(count, "inline copy", "inline copies")


def joined(words: list[str]) -> str:
    """`a`, `a and b`, `a, b and c`."""
    if len(words) > 1:
        return ", ".join(words[:-1]) + " and " + words[-1]
    return words[0] if words else ""


# What each group's updates are called when they are counted.
NOUNS = (("action", "GitHub Action"), ("image", "container image digest"), ("manifest", "tool pin"))


def in_group(applied: list[dict], group: str) -> list[dict]:
    return sorted((task for task in applied if task["group"] == group), key=lambda task: task["label"])


def summary_phrase(applied: list[dict], fixes: list[dict]) -> str:
    """`8 GitHub Actions, 17 container image digests and 11 tool pins`, for titles and changelogs."""
    words = [plural(len(in_group(applied, group)), noun) for group, noun in NOUNS if in_group(applied, group)]
    if fixes:
        words.append(copies(len(fixes)))
    return joined(words) or "nothing"


def title_for(applied: list[dict], fixes: list[dict]) -> str:
    if len(applied) == 1 and not fixes:
        task = applied[0]
        if task["group"] == "image":
            return "chore(deps): re-pinned `%s` to the digest its tag resolves to now" % task["label"]
        return "chore(deps): bumped `%s` to `%s`" % (task["label"], task["apply"]["new"])
    if applied:
        return "chore(deps): bumped %s to their latest upstream releases" % plural(
            len(applied), "pinned dependency", "pinned dependencies")
    if fixes:
        return "chore(deps): realigned %s with `pinned-versions.sh`" % copies(len(fixes))
    return "chore(deps): every pinned dependency is current"


def change_list(applied: list[dict], group: str, moves: bool = False) -> str:
    """`label` `new` pairs for one group; with `moves`, `label` `old` -> `new`, as a hand-written bump reads."""
    rows = in_group(applied, group)
    if group == "image":
        return ", ".join("`%s`" % task["label"] for task in rows)
    if moves:
        return ", ".join("`%s` `%s` -> `%s`" % (task["label"], task["current"], task["apply"]["new"])
                         for task in rows)
    return ", ".join("`%s` `%s`" % (task["label"], task["apply"]["new"]) for task in rows)


def copies_clause(fixes: list[dict]) -> str:
    clause = "kept %s in step with `pinned-versions.sh`" % copies(len(fixes))
    drifted = sum(1 for fix in fixes if fix["drifted"])
    if drifted:
        clause += " (%d of them already out of step before this change)" % drifted
    return clause


def changelog_body(applied: list[dict], fixes: list[dict]) -> str:
    clauses = []
    for group, noun in NOUNS:
        rows = in_group(applied, group)
        if not rows:
            continue
        clause = "%s (%s)" % (plural(len(rows), noun), change_list(applied, group))
        if any(task["apply"].get("digests") for task in rows):
            clause += ", each binary's new SHA-256 taken from its release asset"
        clauses.append(clause)
    body = ""
    if clauses:
        body = ("bumped the pinned dependencies the scheduled `Dependency Updates` workflow found outdated: "
                + joined(clauses))
    if fixes:
        body = (body + "; " + copies_clause(fixes)) if body else copies_clause(fixes)
    return body


def commit_message(applied: list[dict], fixes: list[dict], digest: str) -> str:
    lines = [title_for(applied, fixes), ""]
    if in_group(applied, "action"):
        lines.append("- bumped GitHub Actions: %s" % change_list(applied, "action", moves=True))
    if in_group(applied, "image"):
        lines.append("- re-resolved %s: %s" % (plural(len(in_group(applied, "image")), "image digest"),
                                               change_list(applied, "image")))
    if in_group(applied, "manifest"):
        lines.append("- bumped tool pins with their checksums: %s" % change_list(applied, "manifest", moves=True))
    if fixes:
        lines.append("- " + copies_clause(fixes))
    lines.extend(["", "%s %s" % (TRAILER, digest)])
    return "\n".join(lines) + "\n"


def table(*columns: str) -> list[str]:
    """A Markdown table's header row and the rule beneath it."""
    return ["| %s |" % " | ".join(columns), "|" + "---|" * len(columns)]


def code_row(*cells: str) -> str:
    """A Markdown table row whose every cell is a code span."""
    return "| %s |" % " | ".join("`%s`" % cell for cell in cells)


def bullet(label: str, text: str) -> str:
    return "- `%s`: %s" % (label, text)


def major_mark(current: str, new: str) -> str:
    return "**major**" if is_major(current, new) else ""


INTRO = ("Every pin below has a newer release upstream than the one this repository runs. The scheduled "
         "`Dependency Updates` workflow resolved each new value from the release itself and opened this pull "
         "request; nothing here is merged until a person decides to.")
ACTIONS_NOTE = ("Every `uses:` of each action, sub-path actions included, is re-pinned to the commit its "
                "release tag points at, with the comment moved to the new version.")
IMAGES_NOTE = ("Same tag, new digest: the image was rebuilt upstream under the tag this repository already "
               "uses, which is almost always a base-image security refresh. Moving to a different tag stays a "
               "decision this workflow never makes.")
TOOLS_NOTE = ("Each digest describes the asset of the NEW version: the `# asset:` template that located it "
              "first reproduced the committed digest of the current one, which is what proves it names the file "
              "the installer verifies.")
ERRORS_NOTE = ("These could not be checked at all on this run, so they are neither proposed nor known to be "
               "current:")
DECIDING = [
    "- **Merge** to take every update above.",
    ("- **Close** to decline this set: the workflow does not propose it again, and opens a new pull request "
     + "only once upstream releases something newer."),
    ("- **Stop tracking** one dependency for good by adding its name to `.dependency-updates.json` "
     + "(`{\"ignore\": [\"actions/checkout\"]}`)."),
    ("- **Edit** freely: a commit pushed to this branch by hand is never overwritten. The workflow stops "
     + "updating the branch until the pull request is merged or closed."),
]
CHECKS_NOTE = ("No checks on this pull request? It was opened with the default `GITHUB_TOKEN`, and GitHub does "
               "not let that token start workflows. Close and reopen the pull request to run them, or give the "
               "workflow a `dependency_updates_token`: a personal access token's pull requests do start them.")
TRUNCATED = "\n\n*Truncated: see the workflow run's job summary for the full report.*\n"


def actions_section(applied: list[dict]) -> list[str]:
    actions = in_group(applied, "action")
    if not actions:
        return []
    lines = ["## GitHub Actions (%d)" % len(actions), ""] + table("action", "pinned", "proposed", "")
    for task in actions:
        plan = task["apply"]
        lines.append("| [`%s`](%s) | `%s` | `%s` (`%s`) | %s |" % (
            task["label"], release_link(task), task["current"], plan["new"], plan["sha"][:12],
            major_mark(task["current"], plan["new"])))
    lines.extend(["", ACTIONS_NOTE, ""])
    return lines


def images_section(applied: list[dict]) -> list[str]:
    images = in_group(applied, "image")
    if not images:
        return []
    lines = ["## Container images (%d)" % len(images), ""] + table("image", "pinned digest", "proposed digest")
    lines.extend(code_row(task["label"], short_digest(task["current"]), short_digest(task["apply"]["new"]))
                 for task in images)
    lines.extend(["", IMAGES_NOTE, ""])
    return lines


def checksum_note(plan: dict) -> str:
    """What a reviewer can rely on for one tool pin's new value."""
    if plan["digests"]:
        sources = sorted({digest["source"] for digest in plan["digests"]})
        return "%s: %s" % (plural(len(plan["digests"]), "digest"), "; ".join(sources))
    if is_major_only(plan["new"]):
        return "a major-only range: the newest `%s.x` is installed from its registry" % plan["new"]
    return "installed by exact version from its registry"


def tools_section(applied: list[dict]) -> list[str]:
    tools = in_group(applied, "manifest")
    if not tools:
        return []
    lines = ["## Tools and packages (%d)" % len(tools), ""] + table("pin", "pinned", "proposed", "checksums")
    for task in tools:
        plan = task["apply"]
        link = release_link(task)
        label = "[`%s`](%s)" % (task["label"], link) if link else "`%s`" % task["label"]
        mark = major_mark(task["current"], plan["new"])
        lines.append("| %s%s | `%s` | `%s` | %s |" % (
            label, " " + mark if mark else "", task["current"], plan["new"], checksum_note(plan)))
    lines.extend(["", TOOLS_NOTE, ""])
    return lines


def copies_section(fixes: list[dict]) -> list[str]:
    if not fixes:
        return []
    lines = ["## Inline copies kept in step (%d)" % len(fixes), ""] + table("file", "mirrors", "from", "to")
    for fix in sorted(fixes, key=lambda fix: (fix["file"], fix["var"])):
        show = short_digest if is_digest_var(fix["var"]) else str
        lines.append("| `%s` | `%s` | `%s`%s | `%s` |" % (
            fix["file"], fix["var"], show(fix["from"]),
            " (was already out of step)" if fix["drifted"] else "", show(fix["to"])))
    lines.append("")
    return lines


def needs_person_section(refused: list[dict], unannotated: list[dict]) -> list[str]:
    if not refused and not unannotated:
        return []
    lines = ["## Not in this pull request: needs a person (%d)" % (len(refused) + len(unannotated)), ""]
    for task in sorted(refused, key=lambda task: (task["group"], task["label"])):
        lines.append("- `%s` `%s` -> `%s`: %s" % (task["label"], shown(task, task["current"]),
                                                 md_safe(shown(task, task.get("latest", ""))),
                                                 md_safe(task["refused"])))
    lines.extend(bullet(row["name"], "no `# %s:` annotation, so it is not being checked" % row["missing"])
                 for row in unannotated)
    lines.append("")
    return lines


def errors_section(errors: list[dict], preamble: str | None = None) -> list[str]:
    if not errors:
        return []
    lines = ["## Lookup errors (%d)" % len(errors), ""]
    if preamble:
        lines.extend([preamble, ""])
    lines.extend(bullet(row["label"], md_safe(row["error"])) for row in errors)
    lines.append("")
    return lines


def deciding_section(changelog: str | None) -> list[str]:
    lines = ["## Deciding", ""] + DECIDING + [""]
    if changelog:
        lines.extend(["The change is recorded in `%s`." % changelog, ""])
    lines.append(CHECKS_NOTE)
    return lines


def render_pull_request(applied: list[dict], refused: list[dict], errors: list[dict], unannotated: list[dict],
                        fixes: list[dict], digest: str, changelog: str | None) -> str:
    lines = ["<!-- %s %s -->" % (MARKER, digest), "", INTRO, "",
             "**Proposed: %s.**" % summary_phrase(applied, fixes), ""]
    for section in (actions_section(applied), images_section(applied), tools_section(applied),
                    copies_section(fixes), needs_person_section(refused, unannotated),
                    errors_section(errors, ERRORS_NOTE), deciding_section(changelog)):
        lines.extend(section)
    body = "\n".join(lines) + "\n"
    # GitHub refuses a body over 65536 characters. Far beyond any real run, but
    # a truncated body beats a pull request that cannot be opened at all.
    if len(body) > 60000:
        body = body[:60000] + TRUNCATED
    return body


def changelog_time(root: Path, explicit: str | None) -> datetime.datetime:
    """When the changelog entry says it was written: deterministic, so a rerun changes nothing.

    The time of the commit the branch is built on, rather than the time of the
    run. A rerun against an unchanged default branch then writes byte-identical
    files, so the pull request is not force-pushed -- and its approvals are not
    dismissed -- twice a week for no change at all.
    """
    if explicit:
        value = datetime.datetime.fromisoformat(explicit.replace("Z", "+00:00"))
    else:
        try:
            head = subprocess.run(["git", "-C", str(root), "log", "-1", "--format=%cI", "HEAD"],
                                  capture_output=True, text=True, timeout=30, check=True).stdout.strip()
            value = datetime.datetime.fromisoformat(head)
        except (OSError, subprocess.SubprocessError, ValueError):
            value = datetime.datetime.now(datetime.timezone.utc)
    if value.tzinfo is None:
        value = value.replace(tzinfo=datetime.timezone.utc)
    return value.astimezone(datetime.timezone.utc).replace(microsecond=0)


UNRELEASED = re.compile(r"^##\s*\[Unreleased\]", re.IGNORECASE)


def insert_unreleased_entry(text: str, body: str) -> str | None:
    """Add `- body` under `## [Unreleased]` > `### Changed` of a Keep a Changelog file, or None."""
    lines = text.splitlines(keepends=True)
    newline = "\r\n" if text.count("\r\n") > text.count("\n") // 2 else "\n"
    bullet = "- " + body + newline
    start = next((index for index, line in enumerate(lines) if UNRELEASED.match(line)), None)
    if start is None:
        return None
    end = next((index for index in range(start + 1, len(lines)) if lines[index].startswith("## ")), len(lines))
    changed = next((index for index in range(start + 1, end)
                    if lines[index].strip().lower() == "### changed"), None)
    if changed is None:
        insert = start + 1
        while insert < end and not lines[insert].strip():
            insert += 1
        block = [newline, "### Changed" + newline, newline, bullet]
        # A blank line before whatever follows -- the next subsection, or the
        # next release's heading -- whichever it turns out to be.
        if insert < len(lines):
            block.append(newline)
        return "".join(lines[:start + 1] + block + lines[insert:])
    insert = changed + 1
    while insert < end and not lines[insert].strip():
        insert += 1
    if insert < end and lines[insert].lstrip().startswith(("-", "*")):
        return "".join(lines[:insert] + [bullet] + lines[insert:])
    return "".join(lines[:changed + 1] + [newline, bullet] + ([newline] if insert < len(lines) else [])
                   + lines[insert:])


def write_changelog(ws: Workspace, body: str, when: datetime.datetime, digest: str) -> str | None:
    """Record the change the way the repository records changes; the path written, or None."""
    root = ws.root
    if (root / ".chlog.yaml").is_file() or (root / ".chlog.yml").is_file() or \
            (root / ".changes" / "unreleased").is_dir():
        # Named the way `chlog new` names fragments -- nanoseconds and four hex
        # characters -- from the deterministic time above and the fingerprint.
        name = ".changes/unreleased/%d-%s.yaml" % (int(when.timestamp()) * 10 ** 9, digest[:4])
        ws.set(root / name, "kind: 'Changed'\nbody: '%s'\ntime: '%s'\n" % (
            body.replace("'", "''"), when.strftime("%Y-%m-%dT%H:%M:%S.000000000Z")))
        return name
    changelog = root / "CHANGELOG.md"
    if changelog.is_file():
        updated = insert_unreleased_entry(ws.text(changelog), body)
        if updated is not None and ws.set(changelog, updated):
            return "CHANGELOG.md"
    return None


# --------------------------------------------------------------------------- #
# Reports
# --------------------------------------------------------------------------- #
HOW_TO_FIX = {
    "manifest": ("bump the *_PINNED_VERSION (or *_SPEC) in "
                 "global/scripts/shared/pinned-versions.sh AND replace every *_SHA256_* "
                 "for it from the upstream checksum manifest"),
    "action": "re-pin the action to the new release's commit SHA and update its `# vX.Y.Z` comment",
    "image": "re-resolve the tag's digest and update every `@sha256:` for it",
}


REPORT_GROUPS = (("manifest", "Pinned binaries and packages"),
                 ("action", "GitHub Actions"),
                 ("image", "Container images"))


@dataclasses.dataclass
class Run:
    """Everything one run found and did, for the reports and the exit status."""

    results: list[dict]
    unannotated: list[dict]
    inline: list[dict]
    applied: list[dict] | None = None
    refused: list[dict] = dataclasses.field(default_factory=list)
    fixes: list[dict] = dataclasses.field(default_factory=list)

    @property
    def outdated(self) -> list[dict]:
        return [row for row in self.results if row.get("outdated")]

    @property
    def errors(self) -> list[dict]:
        return [row for row in self.results if row.get("error")]


def report_header(run: Run) -> list[str]:
    # A pin whose bump failed to prepare is both outdated and in error; it is
    # counted once, as neither up to date nor anything else twice.
    current = sum(1 for row in run.results if not row.get("outdated") and not row.get("error"))
    return (["# Dependency update report", ""]
            + table("checked", "up to date", "updates available", "lookup errors")
            + ["| %d | %d | %d | %d |" % (len(run.results), current, len(run.outdated), len(run.errors)), ""])


def outdated_section(rows: list[dict], group: str, title: str, instructions: bool) -> list[str]:
    if not rows:
        return []
    lines = ["## %s (%d)" % (title, len(rows)), ""]
    if group == "image":
        lines.extend(table("image", "pinned digest", "current digest"))
        lines.extend(code_row(row["label"], row["current"][:19] + "...", md_safe(row["latest"][:19]) + "...")
                     for row in rows)
    else:
        lines.extend(table("dependency", "pinned", "available"))
        lines.extend(code_row(row["label"], row["current"], md_safe(row["latest"])) for row in rows)
    lines.append("")
    if instructions:
        lines.extend(["To apply: %s." % HOW_TO_FIX[group], ""])
    return lines


def drift_section(inline: list[dict]) -> list[str]:
    if not inline:
        return []
    lines = ["## Copies that have drifted from the manifest (%d)" % len(inline), ""]
    lines.extend(table("variable", "file", "inline", "manifest"))
    lines.extend(code_row(row["name"], row["file"], row["inline"], row["manifest"]) for row in inline)
    lines.append("")
    return lines


def unannotated_section(unannotated: list[dict]) -> list[str]:
    if not unannotated:
        return []
    lines = ["## Pins with no annotation to check them by (%d)" % len(unannotated), "",
             "These are not being checked at all. Add the annotation named above each.", ""]
    lines.extend("- `%s` (pinned `%s`): no `# %s:` annotation" % (
        row["name"], row["current"], row.get("missing", "upstream")) for row in unannotated)
    lines.append("")
    return lines


def prepared_section(run: Run) -> list[str]:
    if run.applied is None:
        return []
    lines = ["## Prepared for the pull request", "",
             "%s applied, %s left for a person." % (plural(len(run.applied), "update"),
                                                   plural(len(run.refused), "update")), ""]
    if run.refused:
        lines.extend(bullet(row["label"], md_safe(row["refused"]))
                     for row in sorted(run.refused, key=lambda row: (row["group"], row["label"])))
        lines.append("")
    return lines


def render_markdown(run: Run) -> str:
    lines = report_header(run)
    for group, title in REPORT_GROUPS:
        rows = sorted((row for row in run.outdated if row["group"] == group), key=lambda row: row["label"])
        lines.extend(outdated_section(rows, group, title, run.applied is None))
    lines.extend(drift_section(run.inline))
    lines.extend(unannotated_section(run.unannotated))
    lines.extend(errors_section(run.errors))
    lines.extend(prepared_section(run))
    if not (run.outdated or run.errors or run.inline or run.unannotated):
        lines.extend(["Every pinned dependency is current.", ""])
    return "\n".join(lines)


def within_workdir(raw: str, purpose: str) -> Path:
    """Resolve a command-line path and require it to stay inside the working tree.

    Both paths this validates come from argv -- `--report` and `--fixture` --
    and both are written to or read from, so "wherever you point me" is the
    wrong contract for a CI tool. Every runner in this repository writes under
    `build/reports` relative to the job's working directory, which is what
    `cleanup.sh` hands over, so confining them costs nothing real and makes a
    traversal (`--report ../../etc`) fail here rather than somewhere surprising.

    Resolved with `realpath` first so a symlink cannot be used to step outside
    after the check.
    """
    base = Path(os.path.realpath(os.getcwd()))
    resolved = Path(os.path.realpath(raw))
    if resolved != base and base not in resolved.parents:
        raise SystemExit(
            "refusing to use '%s' for %s: it resolves outside the working directory '%s'"
            % (raw, purpose, base))
    return resolved


def report_path(report_dir: Path, filename: str) -> Path:
    """Join a report file name onto the report directory, refusing to escape it.

    The directory is the CALLER's choice and may legitimately be absolute --
    `cleanup.sh` passes `$REPORT_PATH` -- so it is deliberately not confined to
    the working tree. What is confined is the part this script constructs: the
    resolved file must still sit inside the directory it was given. Same shape
    as `report_path` in languages/dart/analyze/dart_analyze_report.py.
    """
    base = Path(os.path.realpath(report_dir))
    resolved = Path(os.path.realpath(base / filename))
    if resolved.parent != base:
        raise SystemExit(
            "refusing to write '%s' outside the report directory '%s'" % (filename, report_dir))
    return resolved


def read_fixture(raw: str) -> dict:
    """Load the offline fixture, refusing anything that is not a readable file.

    `--fixture` is a path from the command line, so it is validated before being
    opened rather than after: a directory or a dangling path should say so here,
    not surface as an opaque IsADirectoryError three frames down.
    """
    path = within_workdir(raw, "the offline fixture")
    if not path.is_file():
        raise SystemExit("fixture file not found: %s" % raw)
    return json.loads(path.read_text(encoding="utf-8"))


def manifest_for(lookups: Lookups, entry: dict) -> tuple[str | None, str | None]:
    """The pin's checksum manifest at its current version, or why it could not be read."""
    if not entry.get("checksums"):
        return None, None
    try:
        return lookups.text(render(entry["checksums"], entry["current"])), None
    except LookupError_ as error:
        return None, str(error)


def check_digest(lookups: Lookups, entry: dict, digest: dict, manifest_text: str | None) -> tuple[str, str]:
    """`(status, detail)` for one committed digest: OK, MISSING, MISMATCH or ERROR."""
    if not digest["asset"]:
        return "MISSING", "no `# asset:` annotation"
    url = render(digest["asset"], entry["current"])
    try:
        value, source = asset_digest(lookups, url)
    except NotFound as error:
        return "MISSING", str(error)
    except LookupError_ as error:
        return "ERROR", str(error)
    if value != digest["value"]:
        return "MISMATCH", "%s is %s, committed %s" % (url, value, digest["value"])
    if manifest_text is None:
        return "OK", source
    published = published_checksum(manifest_text, url.rsplit("/", 1)[-1])
    if published != value:
        return "MISMATCH", "the checksum manifest says %s" % published
    return "OK", source + ", matching the checksum manifest"


def verify_assets(manifest: list[dict], lookups: Lookups) -> int:
    """Check every `# asset:` template against the digest committed beside it.

    For editing the annotations rather than for CI: it asks upstream about every
    pin, bumped or not, and downloads the few assets GitHub recorded no digest
    for. `--apply` runs the same check for each pin it bumps, so a template that
    stops matching is caught there too -- this is how to catch it before then.
    """
    counts: collections.Counter = collections.Counter()
    for entry in manifest:
        if not entry["digests"]:
            continue
        manifest_text, problem = manifest_for(lookups, entry)
        if problem:
            print("  %-9s %-36s checksums: %s" % ("ERROR", entry["name"], problem))
            counts["ERROR"] += 1
        for digest in entry["digests"]:
            status, detail = check_digest(lookups, entry, digest, manifest_text)
            print("  %-9s %-36s %s" % (status, digest["var"], detail))
            counts[status] += 1
    if counts["ERROR"]:
        return 2
    return 1 if counts["MISSING"] or counts["MISMATCH"] else 0


def parse_arguments(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--repo-dir", default=".", help="repository root to scan")
    parser.add_argument("--report", default=os.environ.get("REPORT_PATH", "build/reports"),
                        help="directory for the JSON and Markdown reports")
    parser.add_argument("--fixture", default=os.environ.get("DEPENDENCY_UPDATES_FIXTURE"),
                        help="JSON of upstream answers; makes the run offline")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--report-only", action="store_true",
                      help="always exit 0; report without failing the build")
    mode.add_argument("--apply", action="store_true",
                      help="rewrite every outdated pin in --repo-dir and write the pull request into --report")
    mode.add_argument("--verify-assets", action="store_true",
                      help="check every `# asset:` template against its committed digest (network)")
    parser.add_argument("--timestamp",
                        help="RFC 3339 time for the changelog entry --apply writes "
                             "(default: the time of the repository's HEAD commit)")
    parser.add_argument("--changelog", choices=("auto", "none"), default="auto",
                        help="whether --apply records the change in the repository's changelog")
    parser.add_argument("--jobs", type=int, default=8, help="parallel upstream lookups")
    return parser.parse_args(argv)


def print_findings(run: Run) -> None:
    for row in sorted(run.outdated, key=lambda row: (row["group"], row["label"])):
        if row["group"] == "image":
            print("  UPDATE  %-52s digest moved" % row["label"])
        else:
            print("  UPDATE  %-52s %s -> %s" % (row["label"], row["current"], row["latest"]))
    for row in run.inline:
        print("  DRIFT   %-52s %s has %s, manifest says %s" % (
            row["name"], row["file"], row["inline"], row["manifest"]))
    for row in run.unannotated:
        print("  UNTRACKED %-50s no '# %s:' annotation" % (row["name"], row.get("missing", "upstream")))


def print_applied(run: Run) -> None:
    for row in sorted(run.applied or [], key=lambda row: (row["group"], row["label"])):
        print("  APPLIED %-52s %s" % (row["label"], shown(row, row["apply"]["new"])))
    for row in run.fixes:
        print("  ALIGNED %-52s %s: %s -> %s" % (row["var"], row["file"], row["from"], row["to"]))
    for row in run.refused:
        print("  REFUSED %-52s %s" % (row["label"], row["refused"]), file=sys.stderr)


def report_payload(run: Run) -> dict:
    return {
        "checked": len(run.results),
        "outdated": [
            {key: value for key, value in row.items() if key not in ("track_major", "entry", "family")}
            for row in run.outdated
        ],
        "errors": [{"label": row["label"], "error": row["error"]} for row in run.errors],
        "drifted_copies": run.inline,
        "unannotated_pins": run.unannotated,
    }


def write_pull_request(ws: Workspace, run: Run, report_dir: Path, args: argparse.Namespace) -> dict:
    """Write the updates and the pull request's files; return what the JSON report records of them."""
    digest = fingerprint(run.applied, run.fixes)
    changelog = None
    if ws.changed() and args.changelog == "auto":
        changelog = write_changelog(ws, changelog_body(run.applied, run.fixes),
                                    changelog_time(ws.root, args.timestamp), digest)
    written = ws.write()
    title = title_for(run.applied, run.fixes)
    files = {
        "pull-request-title.txt": title + "\n",
        "pull-request.md": render_pull_request(run.applied, run.refused, run.errors, run.unannotated,
                                               run.fixes, digest, changelog),
        "commit-message.txt": commit_message(run.applied, run.fixes, digest),
        "fingerprint.txt": digest + "\n",
    }
    for name, content in files.items():
        report_path(report_dir, name).write_text(content, encoding="utf-8")
    print("\n%s rewritten in %s." % (plural(len(written), "file"), ws.root))
    return {
        "title": title,
        "fingerprint": digest,
        "changelog": changelog,
        "changed_files": written,
        "applied": [{"group": row["group"], "label": row["label"], "from": row["current"],
                     "to": row["apply"]["new"]} for row in run.applied],
        "refused": [{"group": row["group"], "label": row["label"], "reason": row["refused"]}
                    for row in run.refused],
        "inline_copies": run.fixes,
    }


def apply_status(run: Run) -> int:
    # Applied updates and realigned copies are the pull request's job now; what
    # is left is what a pull request cannot carry.
    if run.refused or run.unannotated:
        print("\n%s could not be applied, %s untracked."
              % (plural(len(run.refused), "update"), plural(len(run.unannotated), "pin")))
        return 1
    if run.applied or run.fixes:
        print("\n%s applied." % plural(len(run.applied or []) + len(run.fixes), "change"))
    else:
        print("\nEvery pinned dependency is current.")
    return 0


def exit_status(run: Run, args: argparse.Namespace) -> int:
    if args.report_only:
        return 0
    # A lookup that could not be completed fails the run. Reporting it as "up to
    # date" would turn a rate-limited API into a green light that checked
    # nothing, which is worse than not running this at all.
    if run.errors:
        print("\n%d upstream lookup(s) failed; refusing to report a clean result."
              % len(run.errors), file=sys.stderr)
        return 2
    if args.apply:
        return apply_status(run)
    if run.outdated or run.inline or run.unannotated:
        print("\n%d update(s), %d drifted copy/copies, %d untracked pin(s)."
              % (len(run.outdated), len(run.inline), len(run.unannotated)))
        return 1
    print("\nEvery pinned dependency is current.")
    return 0


def main(argv: list[str]) -> int:
    args = parse_arguments(argv)
    root = Path(args.repo_dir).resolve()
    fixture = read_fixture(args.fixture) if args.fixture else None
    ws = Workspace(root)

    if args.verify_assets:
        return verify_assets(discover_manifest(root), Lookups(fixture))

    # Resolved against the WORKING DIRECTORY, not `--repo-dir`. `cleanup.sh`
    # hands this script a path relative to wherever the job runs, and the
    # directory being scanned is a separate question from where the report
    # belongs -- resolving it against the scan root wrote reports into the
    # inspected repository whenever the two differed. The directory itself may
    # be absolute and is deliberately not confined; the file names appended to
    # it are. Checked before anything is looked up or rewritten, so a bad path
    # fails without having touched the repository.
    report_dir = within_workdir(args.report, "the report directory")

    tasks, unannotated, inline, manifest = build_tasks(ws)
    if not tasks:
        print("ERROR: no pinned dependencies discovered -- is --repo-dir correct?", file=sys.stderr)
        return 2

    print("Checking %d pinned dependencies (%s)..." % (
        len(tasks), "offline fixture" if fixture is not None else "live upstreams"))
    with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, args.jobs)) as pool:
        run = Run(list(pool.map(lambda task: resolve(task, fixture), tasks)), unannotated, inline)
    print_findings(run)

    if args.apply:
        prepared, run.fixes = apply_updates(ws, run.results, manifest, Lookups(fixture), args.jobs)
        run.applied = [task for task in prepared if task.get("applied")]
        run.refused = [task for task in prepared if task.get("refused")]
        print_applied(run)
    for row in run.errors:
        print("  ERROR   %-52s %s" % (row["label"], row["error"]), file=sys.stderr)

    report_dir.mkdir(parents=True, exist_ok=True)
    payload = report_payload(run)
    if run.applied is not None:
        payload["pull_request"] = write_pull_request(ws, run, report_dir, args)
    report_path(report_dir, "dependency-updates.json").write_text(
        json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    report_path(report_dir, "dependency-updates.md").write_text(render_markdown(run), encoding="utf-8")
    print("\nReports written to %s" % report_dir)
    return exit_status(run, args)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
