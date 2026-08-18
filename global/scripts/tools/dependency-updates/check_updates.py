#!/usr/bin/env python3
"""Report every pinned third-party dependency that has a newer version upstream.

WHY THIS EXISTS

Everything this repository executes is pinned: actions to a commit SHA, images
to a digest, binaries to a version plus a committed SHA-256, packages to an
exact release. That is what makes a pipeline reproducible, and it is also what
makes it go stale silently -- a pin never tells you it is three CVEs behind. The
whole point of pinning is that nothing moves without a human deciding it should,
so the missing half is something that tells the human when to decide.

This is that half. It reads the pins out of the repository, asks each upstream
what the current version is, and exits non-zero when any of them differ, so a
scheduled pipeline turns "somebody should check" into a red build with a diff-
ready list.

WHAT IT CHECKS

  actions   `uses: owner/repo@<sha> # vX.Y.Z` -> newer release for owner/repo
  images    `name:tag@sha256:...`             -> the tag now resolves elsewhere
  manifest  `*_PINNED_VERSION` / `*_SPEC`     -> newer version upstream
  inline    the same version written twice    -> the two copies disagree

Images are checked by DIGEST rather than by tag, because that is the question
worth asking of a container: `python:3.13-slim` is rebuilt with patched system
packages under the same tag, so "is there a newer tag" would miss every security
rebuild, while "does this tag still resolve to the bytes we pinned" catches them
all. The tag is deliberately not resolved to a "latest" -- choosing to move from
`python:3.13` to `3.14` is a decision, not an update.

FAIL-SAFE DIRECTION

A lookup that cannot be completed is reported as an ERROR and fails the run. It
must never be silently treated as "up to date": a rate-limited GitHub API would
otherwise turn this whole check into a green light that inspected nothing, which
is worse than not running it at all.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import json
import os
import re
import sys
import urllib.error
import urllib.request
from pathlib import Path

USER_AGENT = "rios0rios0-pipelines-dependency-check"
TIMEOUT = 30

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


# --------------------------------------------------------------------------- #
# HTTP
# --------------------------------------------------------------------------- #
class LookupError_(Exception):
    """An upstream could not be consulted. Never treated as 'up to date'."""


def _request(url: str, headers: dict | None = None, method: str = "GET"):
    request = urllib.request.Request(url, method=method)
    request.add_header("User-Agent", USER_AGENT)
    for key, value in (headers or {}).items():
        request.add_header(key, value)
    return urllib.request.urlopen(request, timeout=TIMEOUT)  # noqa: S310 - fixed https hosts


def get_json(url: str, headers: dict | None = None):
    try:
        with _request(url, headers) as response:
            return json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as error:
        if error.code in (403, 429):
            raise LookupError_(
                "%s -> HTTP %s (rate limited; set GITHUB_TOKEN)" % (url, error.code)
            ) from error
        raise LookupError_("%s -> HTTP %s" % (url, error.code)) from error
    except Exception as error:  # noqa: BLE001 - any transport failure is a lookup failure
        raise LookupError_("%s -> %s" % (url, error)) from error


def github_headers() -> dict:
    headers = {"Accept": "application/vnd.github+json"}
    token = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
    if token:
        headers["Authorization"] = "Bearer %s" % token
    return headers


# --------------------------------------------------------------------------- #
# Resolvers -- one per `# upstream:` kind
# --------------------------------------------------------------------------- #
def latest_github_release(repo: str, track_major: str | None = None) -> str:
    if track_major is None:
        data = get_json("https://api.github.com/repos/%s/releases/latest" % repo, github_headers())
        return data.get("tag_name") or ""
    # A pin deliberately held inside a major (GoReleaser 1.x, whose 2.x is a
    # breaking configuration change) needs the newest release WITHIN it, not the
    # newest overall -- otherwise this reports an "update" that is really a
    # migration, every run, forever.
    data = get_json("https://api.github.com/repos/%s/releases?per_page=100" % repo, github_headers())
    best = ""
    for release in data:
        if release.get("draft") or release.get("prerelease"):
            continue
        tag = release.get("tag_name") or ""
        tag_parts = parts(tag)
        if not tag_parts or str(tag_parts[0]) != str(track_major):
            continue
        if not best or parts(tag) > parts(best):
            best = tag
    if not best:
        raise LookupError_("no release found for %s within major %s" % (repo, track_major))
    return best


def latest_github_tag(repo: str, track_major: str | None = None) -> str:
    data = get_json("https://api.github.com/repos/%s/tags?per_page=100" % repo, github_headers())
    best = ""
    for tag in data:
        name = tag.get("name") or ""
        if not parts(name):
            continue
        if track_major is not None and str(parts(name)[0]) != str(track_major):
            continue
        if not best or parts(name) > parts(best):
            best = name
    if not best:
        raise LookupError_("no semver-shaped tag found for %s" % repo)
    return best


def latest_gitlab_tag(project: str, track_major: str | None = None) -> str:
    encoded = urllib.request.quote(project, safe="")
    data = get_json("https://gitlab.com/api/v4/projects/%s/repository/tags?per_page=100" % encoded)
    best = ""
    for tag in data:
        name = tag.get("name") or ""
        if not parts(name):
            continue
        if track_major is not None and str(parts(name)[0]) != str(track_major):
            continue
        if not best or parts(name) > parts(best):
            best = name
    if not best:
        raise LookupError_("no semver-shaped tag found for %s" % project)
    return best


def latest_pypi(package: str, track_major: str | None = None) -> str:
    data = get_json("https://pypi.org/pypi/%s/json" % package)
    if track_major is None:
        return data["info"]["version"]
    best = ""
    for version in data.get("releases", {}):
        version_parts = parts(version)
        if not version_parts or str(version_parts[0]) != str(track_major):
            continue
        if not best or parts(version) > parts(best):
            best = version
    if not best:
        raise LookupError_("no %s release within major %s" % (package, track_major))
    return best


def latest_npm(package: str, track_major: str | None = None) -> str:
    if track_major is None:
        return get_json("https://registry.npmjs.org/%s/latest" % package)["version"]
    data = get_json("https://registry.npmjs.org/%s" % package)
    tag = data.get("dist-tags", {}).get("latest", "")
    best = ""
    for version in data.get("versions", {}):
        version_parts = parts(version)
        if not version_parts or str(version_parts[0]) != str(track_major):
            continue
        if not best or parts(version) > parts(best):
            best = version
    return best or tag


def latest_rubygems(gem: str, track_major: str | None = None) -> str:
    return get_json("https://rubygems.org/api/v1/gems/%s.json" % gem)["version"]


def latest_goproxy(module: str, track_major: str | None = None) -> str:
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
SKIP_DIRS = {".git", "node_modules", "build", ".terraform"}

UPSTREAM = re.compile(r"^#\s*upstream:\s*(?P<kind>[a-z-]+)\s+(?P<coord>\S+)(?P<opts>.*)$")
PIN = re.compile(r'^(?P<name>[A-Z0-9_]+)_PINNED_VERSION="(?P<value>[^"]*)"')
SPEC = re.compile(r'^(?P<name>[A-Z0-9_]+)_SPEC="\$\{[A-Z0-9_]+:-(?P<value>[^}"]*)\}"')
USES = re.compile(
    r"^\s*(?:-\s*)?uses:\s*'(?P<repo>[^'@]+)@(?P<sha>[0-9a-f]{40})'\s*#\s*(?P<version>\S+)")
IMAGE = re.compile(r"^\s*(?:-\s*)?image:\s*'(?P<ref>[^']+@sha256:[0-9a-f]+)'")
FROM = re.compile(r"^FROM\s+(?P<ref>\S+@sha256:[0-9a-f]+)")


def walk(root: Path, suffixes=None, names=None):
    for path in sorted(root.rglob("*")):
        if not path.is_file():
            continue
        if any(part in SKIP_DIRS for part in path.parts):
            continue
        if suffixes and path.suffix in suffixes:
            yield path
        elif names and path.name.startswith(tuple(names)):
            yield path


def spec_version(value: str) -> str:
    """Pull the version out of a package spec (`pdm==2.28.1`, `knip@6.32.2`)."""
    for separator in ("==", "@", ":"):
        if separator in value:
            return value.rsplit(separator, 1)[1]
    return value


def discover_manifest(root: Path) -> list[dict]:
    manifest = root / "global" / "scripts" / "shared" / "pinned-versions.sh"
    entries: list[dict] = []
    # Absent in a CONSUMER's repository, which has no pinned-versions.sh of its
    # own. The action and image scans below are generic, so the check still does
    # something useful there rather than failing on a file it had no reason to
    # expect.
    if not manifest.is_file():
        return entries
    pending = None
    for raw in manifest.read_text(encoding="utf-8").splitlines():
        annotation = UPSTREAM.match(raw.strip())
        if annotation:
            options = dict(
                pair.split("=", 1)
                for pair in annotation.group("opts").split()
                if "=" in pair
            )
            pending = {
                "kind": annotation.group("kind"),
                "coord": annotation.group("coord"),
                "track_major": options.get("track"),
            }
            continue
        match = PIN.match(raw) or SPEC.match(raw)
        if not match:
            if raw.strip() and not raw.lstrip().startswith("#"):
                pending = None
            continue
        value = match.group("value")
        name = match.group("name")
        current = spec_version(value) if SPEC.match(raw) else value
        if pending is None:
            entries.append({"kind": "unannotated", "name": name, "current": current})
        else:
            entry = dict(pending)
            entry.update({"name": name, "current": current})
            entries.append(entry)
        pending = None
    return entries


def discover_actions(root: Path) -> dict[str, str]:
    """Distinct third-party action repositories -> the version comment recorded.

    Sub-path actions (`github/codeql-action/init`) collapse onto their owning
    repository, which is what carries the release.
    """
    found: dict[str, str] = {}
    for path in walk(root, suffixes={".yaml", ".yml"}):
        for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
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


def discover_images(root: Path) -> dict[str, str]:
    found: dict[str, str] = {}
    for path in walk(root, suffixes={".yaml", ".yml"}, names=None):
        for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
            match = IMAGE.match(line)
            if match:
                reference = match.group("ref")
                found[reference] = reference.split("@", 1)[1]
    for path in walk(root, names={"Dockerfile"}):
        for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
            match = FROM.match(line)
            if match:
                reference = match.group("ref")
                found[reference] = reference.split("@", 1)[1]
    return found


# Versions written a second time in a template, because that template has no
# `SCRIPTS_DIR` to source the manifest from. A copy is not a problem; a copy
# that has drifted is, and it drifts silently.
INLINE_COPIES = [
    ("PDM_SPEC", r'pip install[^"\n]*"pdm==([0-9][^"]*)"'),
    ("VULTURE_SPEC", r'pip install[^"\n]*"vulture==([0-9][^"]*)"'),
    ("KNIP_SPEC", r"npx --yes[^\n]*knip@([0-9][^\s'\"]*)"),
    ("GOVULNCHECK", r"go install golang\.org/x/vuln/cmd/govulncheck@v?([0-9][^\s'\"]*)"),
    ("BUNDLER_AUDIT_SPEC", r"gem install bundler-audit -v ([0-9][^\s'\"]*)"),
]


def discover_inline(root: Path, manifest: list[dict]) -> list[dict]:
    expected = {entry["name"]: entry["current"] for entry in manifest}
    findings = []
    for name, pattern in INLINE_COPIES:
        want = expected.get(name) or expected.get(name + "_SPEC") or expected.get(
            name.replace("_SPEC", ""))
        if want is None:
            continue
        compiled = re.compile(pattern)
        for path in walk(root, suffixes={".yaml", ".yml"}):
            text = path.read_text(encoding="utf-8", errors="replace")
            for found in compiled.findall(text):
                if normalise(found) != normalise(want):
                    findings.append({
                        "name": name,
                        "file": str(path.relative_to(root)),
                        "inline": found,
                        "manifest": want,
                    })
    return findings


# --------------------------------------------------------------------------- #
# Checking
# --------------------------------------------------------------------------- #
def resolve(task: dict, fixture: dict | None) -> dict:
    key = "%s:%s" % (task["kind"], task["coord"])
    try:
        if fixture is not None:
            if key not in fixture:
                raise LookupError_("no fixture entry for %s" % key)
            latest = fixture[key]
        elif task["kind"] == "image":
            latest = image_digest(task["coord"])
        else:
            resolver = RESOLVERS.get(task["kind"])
            if resolver is None:
                raise LookupError_("unknown upstream kind '%s'" % task["kind"])
            latest = resolver(task["coord"], task.get("track_major"))
        # A pin deliberately held inside a major reports nothing when upstream's
        # newest release is OUTSIDE that major -- moving from GoReleaser 1.x to
        # 2.x is a migration, not an update, and reporting it every run is how a
        # check gets muted. Applied here rather than only inside the GitHub
        # resolver so it holds for every upstream kind, and so the offline
        # fixture path behaves exactly like the live one.
        track = task.get("track_major")
        if track is not None and task["kind"] != "image":
            latest_parts = parts(latest)
            if not latest_parts or str(latest_parts[0]) != str(track):
                latest = task["current"]

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
    every run, and a check that is always red is a check people stop reading.
    Silencing one of those is a decision worth writing down in a file; silencing
    them by default would hide the ordinary stale pins this tool exists to find.
    """
    config = root / ".dependency-updates.json"
    if not config.is_file():
        return []
    try:
        return list(json.loads(config.read_text(encoding="utf-8")).get("ignore", []))
    except (ValueError, OSError):
        print("WARNING: could not read %s; ignoring nothing" % config, file=sys.stderr)
        return []


def build_tasks(root: Path) -> tuple[list[dict], list[dict], list[dict]]:
    manifest = discover_manifest(root)
    tasks: list[dict] = []
    unannotated: list[dict] = []

    for entry in manifest:
        if entry["kind"] == "unannotated":
            unannotated.append(entry)
            continue
        if entry["kind"] == "none":
            continue
        tasks.append({
            "group": "manifest",
            "label": entry["name"],
            "kind": entry["kind"],
            "coord": entry["coord"],
            "track_major": entry.get("track_major"),
            "current": entry["current"],
        })

    for repo, version in sorted(discover_actions(root).items()):
        tasks.append({
            "group": "action",
            "label": repo,
            "kind": "github-release",
            "coord": repo,
            "track_major": None,
            "current": version,
        })

    for reference, digest in sorted(discover_images(root).items()):
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
        import fnmatch
        kept = []
        for task in tasks:
            if any(fnmatch.fnmatch(task["label"], pattern) for pattern in ignores):
                continue
            kept.append(task)
        tasks = kept

    return tasks, unannotated, discover_inline(root, manifest)


HOW_TO_FIX = {
    "manifest": ("bump the *_PINNED_VERSION (or *_SPEC) in "
                 "global/scripts/shared/pinned-versions.sh AND replace every *_SHA256_* "
                 "for it from the upstream checksum manifest"),
    "action": "re-pin the action to the new release's commit SHA and update its `# vX.Y.Z` comment",
    "image": "re-resolve the tag's digest and update every `@sha256:` for it",
}


def render_markdown(results: list[dict], unannotated: list[dict], inline: list[dict]) -> str:
    outdated = [r for r in results if r.get("outdated")]
    errors = [r for r in results if r.get("error")]
    lines = ["# Dependency update report", ""]
    lines.append("| checked | up to date | updates available | lookup errors |")
    lines.append("|---|---|---|---|")
    lines.append("| %d | %d | %d | %d |" % (
        len(results), len(results) - len(outdated) - len(errors), len(outdated), len(errors)))
    lines.append("")

    for group, title in (("manifest", "Pinned binaries and packages"),
                         ("action", "GitHub Actions"),
                         ("image", "Container images")):
        rows = [r for r in outdated if r["group"] == group]
        if not rows:
            continue
        lines.append("## %s (%d)" % (title, len(rows)))
        lines.append("")
        if group == "image":
            lines.append("| image | pinned digest | current digest |")
            lines.append("|---|---|---|")
            for row in sorted(rows, key=lambda r: r["label"]):
                lines.append("| `%s` | `%s` | `%s` |" % (
                    row["label"], row["current"][:19] + "...", row["latest"][:19] + "..."))
        else:
            lines.append("| dependency | pinned | available |")
            lines.append("|---|---|---|")
            for row in sorted(rows, key=lambda r: r["label"]):
                lines.append("| `%s` | `%s` | `%s` |" % (
                    row["label"], row["current"], row["latest"]))
        lines.append("")
        lines.append("To apply: %s." % HOW_TO_FIX[group])
        lines.append("")

    if inline:
        lines.append("## Copies that have drifted from the manifest (%d)" % len(inline))
        lines.append("")
        lines.append("| variable | file | inline | manifest |")
        lines.append("|---|---|---|---|")
        for row in inline:
            lines.append("| `%s` | `%s` | `%s` | `%s` |" % (
                row["name"], row["file"], row["inline"], row["manifest"]))
        lines.append("")

    if unannotated:
        lines.append("## Pins with no `# upstream:` annotation (%d)" % len(unannotated))
        lines.append("")
        lines.append("These are not being checked at all. Add an annotation above each.")
        lines.append("")
        for row in unannotated:
            lines.append("- `%s` (pinned `%s`)" % (row["name"], row["current"]))
        lines.append("")

    if errors:
        lines.append("## Lookup errors (%d)" % len(errors))
        lines.append("")
        for row in errors:
            lines.append("- `%s`: %s" % (row["label"], row["error"]))
        lines.append("")

    if not outdated and not errors and not inline and not unannotated:
        lines.append("Every pinned dependency is current.")
        lines.append("")
    return "\n".join(lines)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--repo-dir", default=".", help="repository root to scan")
    parser.add_argument("--report", default=os.environ.get("REPORT_PATH", "build/reports"),
                        help="directory for the JSON and Markdown reports")
    parser.add_argument("--fixture", default=os.environ.get("DEPENDENCY_UPDATES_FIXTURE"),
                        help="JSON of {'kind:coord': 'version'}; makes the run offline")
    parser.add_argument("--report-only", action="store_true",
                        help="always exit 0; report without failing the build")
    parser.add_argument("--jobs", type=int, default=8, help="parallel upstream lookups")
    args = parser.parse_args(argv)

    root = Path(args.repo_dir).resolve()
    fixture = json.loads(Path(args.fixture).read_text(encoding="utf-8")) if args.fixture else None

    tasks, unannotated, inline = build_tasks(root)
    if not tasks:
        print("ERROR: no pinned dependencies discovered -- is --repo-dir correct?", file=sys.stderr)
        return 2

    print("Checking %d pinned dependencies (%s)..." % (
        len(tasks), "offline fixture" if fixture is not None else "live upstreams"))
    with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, args.jobs)) as pool:
        results = list(pool.map(lambda task: resolve(task, fixture), tasks))

    outdated = [r for r in results if r.get("outdated")]
    errors = [r for r in results if r.get("error")]

    for row in sorted(outdated, key=lambda r: (r["group"], r["label"])):
        if row["group"] == "image":
            print("  UPDATE  %-52s digest moved" % row["label"])
        else:
            print("  UPDATE  %-52s %s -> %s" % (row["label"], row["current"], row["latest"]))
    for row in inline:
        print("  DRIFT   %-52s %s has %s, manifest says %s" % (
            row["name"], row["file"], row["inline"], row["manifest"]))
    for row in unannotated:
        print("  UNTRACKED %-50s no '# upstream:' annotation" % row["name"])
    for row in errors:
        print("  ERROR   %-52s %s" % (row["label"], row["error"]), file=sys.stderr)

    # Resolved against the WORKING DIRECTORY, not `--repo-dir`. `cleanup.sh`
    # hands this script a path relative to wherever the job runs, and the
    # directory being scanned is a separate question from where the report
    # belongs -- resolving it against the scan root wrote reports into the
    # inspected repository whenever the two differed. The directory itself may
    # be absolute and is deliberately not confined; the file names appended to
    # it are.
    report_dir = Path(os.path.realpath(args.report))
    report_dir.mkdir(parents=True, exist_ok=True)
    payload = {
        "checked": len(results),
        "outdated": [
            {k: v for k, v in row.items() if k != "track_major"} for row in outdated
        ],
        "errors": [{"label": r["label"], "error": r["error"]} for r in errors],
        "drifted_copies": inline,
        "unannotated_pins": unannotated,
    }
    (report_dir / "dependency-updates.json").write_text(
        json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    (report_dir / "dependency-updates.md").write_text(
        render_markdown(results, unannotated, inline), encoding="utf-8")
    print("\nReports written to %s" % report_dir)

    if args.report_only:
        return 0
    # A lookup that could not be completed fails the run. Reporting it as "up to
    # date" would turn a rate-limited API into a green light that checked
    # nothing, which is worse than not running this at all.
    if errors:
        print("\n%d upstream lookup(s) failed; refusing to report a clean result."
              % len(errors), file=sys.stderr)
        return 2
    if outdated or inline or unannotated:
        print("\n%d update(s), %d drifted copy/copies, %d untracked pin(s)."
              % (len(outdated), len(inline), len(unannotated)))
        return 1
    print("\nEvery pinned dependency is current.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
