#!/usr/bin/env sh

# Shared helpers for the Dart / Flutter language scripts.
#
# This file is SOURCED, never executed, so it carries no `run.sh` name and no
# executable bit -- same contract as `global/scripts/deploy/common.sh`.
#
# Three decisions shape this family; none of them is incidental.
#
# 1. THE SDK IS INSTALLED FROM GOOGLE'S OWN ARCHIVE, NEVER FROM DOCKER HUB.
#    The obvious way to get Flutter into CI is `image: ghcr.io/cirruslabs/flutter`
#    or `docker run instrumentisto/flutter`, and the obvious way is the one this
#    repository has already ruled out everywhere else: Docker Hub rate-limits
#    anonymous pulls, so a cache-cold runner fails the whole job with
#    `toomanyrequests` for a reason unrelated to the code under scan. Both SDKs
#    publish plain archives on `storage.googleapis.com`, which is neither rate
#    limited nor a third-party mirror, so that is what these scripts fetch.
#
# 2. EVERY SCRIPT IS SELF-SUFFICIENT ABOUT THE SDK.
#    CI jobs on all three platforms run each step in a fresh shell, so a `PATH`
#    exported by a previous step is gone. Rather than make every template repeat
#    an install step, each `run.sh` calls `dart_ensure_sdk`, which reuses an SDK
#    already on `PATH` (or already unpacked under `~/.local/share`) and only
#    downloads when there is nothing to reuse. The cost of the check is one
#    `command -v`.
#
# 3. `DART_DRY_RUN=true` RESOLVES AND RECORDS COMMANDS WITHOUT RUNNING THEM.
#    This is the only reason `make test` can exercise the whole Dart family
#    offline, on a machine with no Dart SDK, no Flutter SDK and no network. A
#    dry run installs nothing and touches no network, so the validation harness
#    asserts on the argv each script actually builds rather than on what the
#    source looks like it says -- the same technique `test-deploy-providers.sh`
#    and `test-dependency-check.sh` already use.

# The integrity-checked downloader, used for both SDK archives below. Sourced
# here rather than in each `run.sh` because `common.sh` is the one file every
# Dart script already loads.
. "$SCRIPTS_DIR/global/scripts/shared/verify-download.sh"

# dart_is_truthy <value>
#
# Case-insensitive boolean test. Azure DevOps stringifies a `boolean` template
# parameter as `True` / `False` (PascalCase), so a strict `= "true"` comparison
# silently turns a requested dry run into a real run on that platform alone.
# Same reasoning as `deploy_is_truthy`.
dart_is_truthy() {
  case "$(printf '%s' "${1:-false}" | tr '[:upper:]' '[:lower:]')" in
    true | 1 | yes) return 0 ;;
    *) return 1 ;;
  esac
}

# dart_is_dry_run
dart_is_dry_run() {
  dart_is_truthy "${DART_DRY_RUN:-false}"
}

# dart_report_root
#
# The directory every Dart script writes into. `PREFIX` is honoured because the
# GitLab templates set it (see `gitlab/python/stages/35-management/pdm.yaml`).
#
# The value is memoised on first use. That is not a micro-optimisation: the
# shared `cleanup.sh` REWRITES `REPORT_PATH` to a per-tool subdirectory, so a
# root recomputed from `REPORT_PATH` after any such rewrite would nest one level
# deeper on every call and land the reports somewhere no template looks. Pinning
# it once removes the ordering dependency entirely.
dart_report_root() {
  if [ -z "${DART_REPORT_ROOT:-}" ]; then
    DART_REPORT_ROOT="${PREFIX:-}${REPORT_PATH:-build/reports}"
    export DART_REPORT_ROOT
  fi
  printf '%s' "$DART_REPORT_ROOT"
}

# dart_prepare_reports <name>
#
# Create this job's private report directory under the report root and point the
# command journal at it. Exports:
#
#   DART_TOOL_REPORT_PATH -- <root>/<name>, freshly emptied
#   DART_COMMAND_LOG      -- <root>/<name>/command.txt
#
# `REPORT_PATH` itself is deliberately left ALONE. The test runner publishes
# `junit.xml` and `cobertura.xml` at the report root (that is where every
# platform's publish step looks for them) while still wanting a private command
# journal, so a helper that redirected `REPORT_PATH` would force that script to
# undo the redirection. Being explicit about which of the two paths each file
# belongs to is shorter than the alternative and impossible to get subtly wrong.
#
# The journal is APPENDED to, not overwritten as in the deploy family: a Dart
# job legitimately runs several commands in sequence (activate a global package,
# fetch dependencies, run tests, format coverage), and the interesting assertion
# is usually the whole sequence rather than its last line.
dart_prepare_reports() {
  DART_TOOL_REPORT_PATH="$(dart_report_root)/$1"
  export DART_TOOL_REPORT_PATH
  rm -rf "$DART_TOOL_REPORT_PATH"
  mkdir -p "$DART_TOOL_REPORT_PATH"

  DART_COMMAND_LOG="$DART_TOOL_REPORT_PATH/command.txt"
  export DART_COMMAND_LOG
  : > "$DART_COMMAND_LOG"
}

# dart_run <command> [args...]
#
# Record the resolved command line, then run it -- or, on a dry run, stop at the
# recording and return success so the rest of the script continues to resolve.
#
# Recording unconditionally (not only on the dry-run path) means a failed real
# job also leaves the exact invocation that failed in its published artifact,
# which is the first thing anyone debugging a red job asks for.
#
# EVERY line this function prints itself goes to STDERR, and that is load-
# bearing rather than stylistic. Several callers capture the wrapped command's
# stdout because that stdout IS the machine-readable payload -- `dart test
# --reporter json`, `flutter test --machine` and `osv-scanner --format json` all
# write their entire result there. A progress line on stdout would be
# interleaved into that payload, and the consumer on the other side (`tojunit`,
# `jq`) would reject the whole document over one unexpected leading line. The
# command journal, not stdout, is what the validation harness asserts on.
dart_run() {
  if [ -n "${DART_COMMAND_LOG:-}" ]; then
    printf '%s\n' "$*" >> "$DART_COMMAND_LOG"
  fi

  if dart_is_dry_run; then
    echo "DRY RUN (not executed): $*" >&2
    return 0
  fi

  echo "Running: $*" >&2
  "$@"
}

# dart_detect_toolchain
#
# Echo `flutter` or `dart`. An explicit `DART_TOOLCHAIN` always wins; otherwise
# the project's own `pubspec.yaml` decides.
#
# The detection reads the `sdk: flutter` dependency rather than the top-level
# `flutter:` key. A pure Dart package can carry a `flutter:` section (to declare
# assets consumed by a dependent app) without depending on Flutter at all, while
# EVERY Flutter project -- app, plugin and package alike -- declares
# `flutter:\n    sdk: flutter` under `dependencies`. Getting this backwards
# picks the wrong CLI, and the failure is confusing rather than obvious: `dart
# test` on a Flutter project fails deep inside the widget-test bindings.
dart_detect_toolchain() {
  if [ -n "${DART_TOOLCHAIN:-}" ] && [ "$DART_TOOLCHAIN" != "auto" ]; then
    printf '%s' "$DART_TOOLCHAIN"
    return 0
  fi

  if [ -f "${DART_PUBSPEC:-pubspec.yaml}" ] &&
    grep -qE '^[[:space:]]+sdk:[[:space:]]*flutter[[:space:]]*$' "${DART_PUBSPEC:-pubspec.yaml}"; then
    printf 'flutter'
  else
    printf 'dart'
  fi
}

# dart_sdk_install_dir
#
# The PARENT directory both SDKs are unpacked into (they each carry their own
# top-level directory inside the archive, `dart-sdk/` and `flutter/`).
#
# Overridable via `DART_SDK_INSTALL_DIR` because GitLab CI can only cache paths
# INSIDE `$CI_PROJECT_DIR` -- an SDK under `$HOME` is re-downloaded by every job
# of every pipeline there, which for Flutter is several hundred megabytes each
# time. The GitLab templates point this at `$CI_PROJECT_DIR/.sdk` and cache it.
dart_sdk_install_dir() {
  printf '%s' "${DART_SDK_INSTALL_DIR:-$HOME/.local/share}"
}

# dart_sdk_arch
#
# Map `uname -m` onto the architecture slug Google uses in both archive layouts
# (`x64` / `arm64`). Unknown architectures fail loudly rather than producing a
# 404 that reads like a network problem.
dart_sdk_arch() {
  case "$(uname -m)" in
    x86_64 | amd64) printf 'x64' ;;
    aarch64 | arm64) printf 'arm64' ;;
    *)
      echo "ERROR: no Dart/Flutter SDK archive is published for architecture '$(uname -m)'." >&2
      echo "Supported: x86_64 (x64) and aarch64 (arm64). Run this stage on a supported runner." >&2
      exit 1
      ;;
  esac
}

# dart_extract_archive <archive> <destination-dir>
#
# Unpack a `.zip` or `.tar.xz` without assuming which extractors the runner has.
# `unzip` in particular is absent from several slim CI images, and its absence
# used to surface as `unzip: not found` three lines after a successful download.
# Python 3 is already a hard dependency of the Semgrep tool script, so it is the
# fallback for both formats.
dart_extract_archive() {
  _da_archive="$1"
  _da_dest="$2"

  mkdir -p "$_da_dest"
  case "$_da_archive" in
    *.zip)
      if command -v unzip > /dev/null 2>&1; then
        unzip -q "$_da_archive" -d "$_da_dest"
      elif command -v python3 > /dev/null 2>&1; then
        python3 -m zipfile -e "$_da_archive" "$_da_dest"
      else
        echo "ERROR: cannot unpack '$_da_archive' -- neither 'unzip' nor 'python3' is available." >&2
        exit 1
      fi
      ;;
    *.tar.xz)
      # BusyBox tar understands `-J`; GNU tar does too. `xz` itself is the part
      # that is occasionally missing, and tar reports that clearly.
      tar -xJf "$_da_archive" -C "$_da_dest"
      ;;
    *)
      echo "ERROR: unsupported archive format for '$_da_archive'." >&2
      exit 1
      ;;
  esac

  unset _da_archive _da_dest
  return 0
}

# dart_install_dart_sdk
#
# Install the standalone Dart SDK under `~/.local/share/dart-sdk`.
#
# `DART_SDK_VERSION` defaults to `latest`, which the archive server accepts as a
# path segment -- so the common case needs no version lookup and no `jq`.
dart_install_dart_sdk() {
  _dd_channel="${DART_SDK_CHANNEL:-stable}"
  _dd_version="${DART_SDK_VERSION:-latest}"
  _dd_arch="$(dart_sdk_arch)"
  _dd_root="$(dart_sdk_install_dir)/dart-sdk"

  if [ -x "$_dd_root/bin/dart" ]; then
    echo "Reusing the Dart SDK already unpacked at $_dd_root."
  else
    _dd_url="https://storage.googleapis.com/dart-archive/channels/$_dd_channel/release/$_dd_version/sdk/dartsdk-linux-$_dd_arch-release.zip"
    echo "Downloading the Dart SDK ($_dd_channel/$_dd_version/$_dd_arch)..."
    # Verified against the `.sha256sum` Google publishes beside every archive,
    # rather than against a digest committed here.
    #
    # The distinction matters and is worth stating plainly: which Dart SDK a
    # project builds with is the CONSUMER's choice (`DART_SDK_CHANNEL`,
    # `DART_SDK_VERSION`, and `latest` by default), so this repository cannot
    # know the version in advance and cannot commit its digest. That makes this
    # weaker than the pinned tools -- a compromised publisher would serve a
    # matching checksum too. It is still a real gain over the nothing that was
    # checked before: it catches a truncated or corrupted transfer, a cache
    # serving the wrong bytes, and any tamper that cannot also rewrite a second
    # HTTPS request. A consumer wanting the strong guarantee pins
    # `DART_SDK_VERSION` and verifies the SDK out of band.
    if ! download_verified_against_manifest \
      "$_dd_url" /tmp/dartsdk.zip "$_dd_url.sha256sum" \
      "dartsdk-linux-$_dd_arch-release.zip"; then
      echo "ERROR: could not install the Dart SDK from $_dd_url" >&2
      echo "Check DART_SDK_CHANNEL ('stable', 'beta' or 'dev') and DART_SDK_VERSION." >&2
      exit 1
    fi
    # The archive already contains a top-level `dart-sdk/` directory, so extract
    # into the PARENT and let it create that directory itself.
    rm -rf "$_dd_root"
    dart_extract_archive /tmp/dartsdk.zip "$(dart_sdk_install_dir)"
    rm -f /tmp/dartsdk.zip
    chmod +x "$_dd_root/bin/dart" 2>/dev/null || true
  fi

  ln -sf "$_dd_root/bin/dart" "$HOME/.local/bin/dart"

  unset _dd_channel _dd_version _dd_arch _dd_root _dd_url
  return 0
}

# dart_resolve_flutter_archive <channel>
#
# Echo the archive path (relative to the releases base URL) for the requested
# Flutter release.
#
# An explicit `FLUTTER_VERSION` short-circuits the lookup and composes the path
# directly, so pinning a version needs neither the network manifest nor `jq`.
# Resolving "whatever is current on this channel" does need the manifest, and
# `jq` with it; that is stated in the error rather than left to a `jq: not
# found` further down.
dart_resolve_flutter_archive() {
  _df_channel="$1"
  _df_arch="$(dart_sdk_arch)"

  if [ -n "${FLUTTER_VERSION:-}" ]; then
    if [ "$_df_arch" = "arm64" ]; then
      printf '%s/linux/flutter_linux_arm64_%s-%s.tar.xz' "$_df_channel" "$FLUTTER_VERSION" "$_df_channel"
    else
      printf '%s/linux/flutter_linux_%s-%s.tar.xz' "$_df_channel" "$FLUTTER_VERSION" "$_df_channel"
    fi
    return 0
  fi

  if ! command -v jq > /dev/null 2>&1; then
    echo "ERROR: resolving the current Flutter '$_df_channel' release needs 'jq' to read the release manifest." >&2
    echo "Install jq on the runner, or pin an exact version with FLUTTER_VERSION (e.g. FLUTTER_VERSION=3.47.0)." >&2
    exit 1
  fi

  _df_manifest="$(mktemp)"
  if ! curl -fsSL --show-error --proto '=https' --proto-redir '=https' \
    "https://storage.googleapis.com/flutter_infra_release/releases/releases_linux.json" \
    -o "$_df_manifest"; then
    echo "ERROR: could not download the Flutter release manifest." >&2
    rm -f "$_df_manifest"
    exit 1
  fi

  # Pick the release whose hash the manifest names as current for the channel,
  # narrowed to this machine's architecture -- the manifest carries x64 and
  # arm64 entries under the same hash.
  _df_archive="$(jq -r --arg ch "$_df_channel" --arg arch "$_df_arch" '
    .current_release[$ch] as $hash
    | [ .releases[]
        | select(.hash == $hash and .channel == $ch and ((.dart_sdk_arch // "x64") == $arch)) ]
    | first
    | .archive // empty
  ' "$_df_manifest")"
  rm -f "$_df_manifest"

  if [ -z "$_df_archive" ]; then
    echo "ERROR: the Flutter manifest lists no '$_df_channel' release for architecture '$_df_arch'." >&2
    echo "Pin one explicitly with FLUTTER_VERSION." >&2
    exit 1
  fi

  printf '%s' "$_df_archive"
  unset _df_channel _df_arch _df_manifest _df_archive
  return 0
}

# dart_flutter_archive_sha256 <channel> <archive-path>
#
# Echo the SHA-256 `releases_linux.json` publishes for a given archive, or
# nothing when it publishes none.
#
# The manifest carries a `sha256` beside every release, which is what makes the
# Flutter SDK download verifiable at all -- the version is the consumer's to
# choose (`FLUTTER_VERSION`, or "current on this channel"), so no digest for it
# can be committed here. Echoing empty rather than failing is deliberate: an
# older manifest entry may carry no `sha256`, and a missing digest must degrade
# to a warned, unverified download rather than break a Flutter build outright.
#
# Needs `jq`, exactly like the resolver above. When `FLUTTER_VERSION` is pinned
# the resolver never reads the manifest, so `jq` may legitimately be absent --
# hence the quiet return instead of the resolver's hard error.
dart_flutter_archive_sha256() {
  _dfs_channel="$1"
  _dfs_archive="$2"

  if ! command -v jq > /dev/null 2>&1; then
    return 0
  fi

  _dfs_manifest="$(mktemp)"
  if ! curl -fsSL --proto '=https' --proto-redir '=https' \
    "https://storage.googleapis.com/flutter_infra_release/releases/releases_linux.json" \
    -o "$_dfs_manifest" 2>/dev/null; then
    rm -f "$_dfs_manifest"
    return 0
  fi

  jq -r --arg archive "$_dfs_archive" '
    [ .releases[] | select(.archive == $archive) ] | first | .sha256 // empty
  ' "$_dfs_manifest" 2>/dev/null

  rm -f "$_dfs_manifest"
  unset _dfs_channel _dfs_archive _dfs_manifest
  return 0
}

# dart_install_flutter_sdk
#
# Install the Flutter SDK under `~/.local/share/flutter` and symlink both
# `flutter` and its bundled `dart` into `~/.local/bin`.
#
# Symlinking `dart` matters: `dart analyze --format=machine` is the only
# machine-readable analyzer output there is (`flutter analyze` has no `--format`
# -- flutter/flutter#95090), so the analyze and format jobs drive `dart` even on
# a Flutter project. It must be the Flutter SDK's OWN Dart, not a separately
# installed one, or the analysis runs against a different SDK than the app is
# built with and reports imports it cannot resolve.
dart_install_flutter_sdk() {
  _dfi_channel="${FLUTTER_CHANNEL:-stable}"
  _dfi_root="$(dart_sdk_install_dir)/flutter"

  if [ -x "$_dfi_root/bin/flutter" ]; then
    echo "Reusing the Flutter SDK already unpacked at $_dfi_root."
  else
    _dfi_archive="$(dart_resolve_flutter_archive "$_dfi_channel")" || exit 1
    _dfi_url="https://storage.googleapis.com/flutter_infra_release/releases/$_dfi_archive"
    echo "Downloading the Flutter SDK ($_dfi_archive)..."
    # `releases_linux.json` carries a `sha256` for every release, and
    # `dart_resolve_flutter_archive` has already fetched and parsed that file to
    # find the archive path -- so the digest is read from the same document,
    # with no second request. Same trade-off as the Dart SDK above: the version
    # is the consumer's to choose, so this verifies transport and storage
    # integrity rather than publisher identity.
    _dfi_sha="$(dart_flutter_archive_sha256 "$_dfi_channel" "$_dfi_archive")"
    if [ -n "$_dfi_sha" ]; then
      if ! download_verified "$_dfi_url" /tmp/flutter-sdk.tar.xz "$_dfi_sha"; then
        exit 1
      fi
    else
      echo "WARNING: no sha256 published for '$_dfi_archive'; downloading without verification." >&2
      if ! download_verified "$_dfi_url" /tmp/flutter-sdk.tar.xz "SKIP"; then
        exit 1
      fi
    fi
    # The archive contains a top-level `flutter/` directory.
    rm -rf "$_dfi_root"
    dart_extract_archive /tmp/flutter-sdk.tar.xz "$(dart_sdk_install_dir)"
    rm -f /tmp/flutter-sdk.tar.xz
  fi

  # The Flutter SDK is a git checkout and `flutter` shells out to git on almost
  # every invocation. When the checkout's owner differs from the process user --
  # routine on shared and containerised runners -- git refuses with `detected
  # dubious ownership in repository`, and `flutter` reports that as its own
  # unrelated-looking startup failure. Marking it safe up front costs nothing
  # and removes a failure mode that is very hard to read from the flutter side.
  if command -v git > /dev/null 2>&1; then
    git config --global --add safe.directory "$_dfi_root" 2>/dev/null || true
  fi

  ln -sf "$_dfi_root/bin/flutter" "$HOME/.local/bin/flutter"
  ln -sf "$_dfi_root/bin/dart" "$HOME/.local/bin/dart"

  unset _dfi_channel _dfi_root _dfi_archive _dfi_url
  return 0
}

# dart_ensure_sdk
#
# Make the toolchain this project needs runnable, and export `DART_TOOLCHAIN`.
# Idempotent and cheap when the SDK is already present.
dart_ensure_sdk() {
  DART_TOOLCHAIN="$(dart_detect_toolchain)"
  export DART_TOOLCHAIN

  mkdir -p "$HOME/.local/bin" "$(dart_sdk_install_dir)"
  case ":$PATH:" in
    *":$HOME/.local/bin:"*) ;;
    *) PATH="$HOME/.local/bin:$PATH" && export PATH ;;
  esac
  # `dart pub global activate` drops launchers here for both toolchains.
  # `PUB_CACHE` is honoured rather than assuming `$HOME/.pub-cache`: the GitLab
  # templates relocate it into `$CI_PROJECT_DIR` so it can be cached, and a
  # hardcoded `$HOME` path would leave `tojunit` and `metrics` off `PATH` there
  # -- installed successfully, then reported as "not found".
  _de_pub_bin="${PUB_CACHE:-$HOME/.pub-cache}/bin"
  mkdir -p "$_de_pub_bin"
  case ":$PATH:" in
    *":$_de_pub_bin:"*) ;;
    *) PATH="$PATH:$_de_pub_bin" && export PATH ;;
  esac
  unset _de_pub_bin

  if dart_is_dry_run; then
    echo "DRY RUN: skipping SDK installation (toolchain resolved as '$DART_TOOLCHAIN')."
    return 0
  fi

  if [ "$DART_TOOLCHAIN" = "flutter" ]; then
    if ! command -v flutter > /dev/null 2>&1; then
      dart_install_flutter_sdk
    fi
    # A pre-installed Flutter (e.g. `subosito/flutter-action`, or a self-hosted
    # agent's own SDK) puts `flutter` on PATH but not always `dart`. Recover the
    # bundled one from the SDK root rather than installing a second SDK.
    if ! command -v dart > /dev/null 2>&1; then
      _de_flutter_bin="$(dirname "$(command -v flutter)")"
      if [ -x "$_de_flutter_bin/dart" ]; then
        ln -sf "$_de_flutter_bin/dart" "$HOME/.local/bin/dart"
      fi
      unset _de_flutter_bin
    fi
  else
    if ! command -v dart > /dev/null 2>&1; then
      dart_install_dart_sdk
    fi
  fi

  return 0
}

# dart_pub_get
#
# Resolve dependencies with the project's own toolchain. `flutter pub get` and
# `dart pub get` are not interchangeable on a Flutter project: only the former
# resolves the `sdk: flutter` pseudo-dependencies.
dart_pub_get() {
  if [ "${DART_SKIP_PUB_GET:-false}" != "false" ] && dart_is_truthy "${DART_SKIP_PUB_GET}"; then
    echo "DART_SKIP_PUB_GET is set; not resolving dependencies."
    return 0
  fi

  if [ "$DART_TOOLCHAIN" = "flutter" ]; then
    dart_run flutter pub get
  else
    dart_run dart pub get
  fi
}

# dart_global_activate <package> [binary]
#
# Install a pub-published CLI (`junitreport`, `dart_code_linter`, `coverage`)
# and make its launcher runnable. Skipped when the launcher is already present,
# so a persistent agent pays for it once.
#
# `dart pub global activate` is used even under Flutter: Flutter's `pub` is the
# same tool and shares `~/.pub-cache`.
dart_global_activate() {
  _dga_package="$1"
  _dga_binary="${2:-$1}"

  if command -v "$_dga_binary" > /dev/null 2>&1; then
    unset _dga_package _dga_binary
    return 0
  fi

  dart_run dart pub global activate "$_dga_package"

  unset _dga_package _dga_binary
  return 0
}

# dart_pubspec_field <field>
#
# Read a top-level scalar from `pubspec.yaml` (`name`, `version`, ...) without a
# YAML parser. Only top-level keys are matched -- the leading-space anchor is
# what stops a nested `version:` under `dependencies:` from winning.
dart_pubspec_field() {
  _dpf_file="${DART_PUBSPEC:-pubspec.yaml}"
  [ -f "$_dpf_file" ] || return 0
  sed -n "s/^$1:[[:space:]]*['\"]\{0,1\}\([^'\"#]*\)['\"]\{0,1\}[[:space:]]*$/\1/p" "$_dpf_file" |
    head -n 1 |
    sed 's/[[:space:]]*$//'
  unset _dpf_file
}
