#!/usr/bin/env sh
# shellcheck shell=sh
# shellcheck disable=SC2034  # every value here is consumed by a script that SOURCES this file
#
# Single source of truth for every third-party binary these pipelines download
# and execute. SOURCED, never executed -- it carries no `run.sh` name and no
# executable bit.
#
# WHY THIS FILE EXISTS
#
# Every tool here used to resolve its own version at run time, almost always
# through GitHub's `releases/latest` redirect, and then run whatever bytes came
# back. Two independent problems followed from that:
#
#   1. NO INTEGRITY. Nothing checked what was downloaded. A compromised upstream
#      account, a hijacked release asset or a CDN able to answer the redirect
#      could put arbitrary code on the runner, which then executed it with the
#      job's credentials in scope -- including, on the SAST jobs, a token that
#      can write to the repository being scanned.
#   2. NO REPRODUCIBILITY. The same pipeline, re-run on the same commit, could
#      install a different tool version and produce a different verdict, so a
#      red build could not be reproduced and a green one proved nothing about
#      what will run tomorrow.
#
# Pinning here fixes both: the version is fixed, the SHA-256 of the exact
# artifact is committed alongside it, and `verify-download.sh` refuses anything
# that does not match. Every value below was recorded from the upstream
# publisher's own checksum manifest where one exists, and computed from the
# published artifact where it does not (ShellCheck, stoml and ProGuard publish
# none).
#
# HOW TO BUMP A TOOL
#
#   1. Change the *_VERSION value.
#   2. Replace every *_SHA256_* value for that tool. Take them from the
#      upstream checksum manifest; do not carry an old digest forward.
#   3. Run `make test-supply-chain`, which re-asserts the shape of every entry.
#
# Each version is overridable from the environment so an operator can respond to
# an upstream CVE without waiting for a release here. Overriding the version
# WITHOUT also supplying the matching checksum is refused by
# `verify-download.sh` rather than silently downgraded to an unverified
# download -- see `download_verified` for how to opt out deliberately.

# --- Security tooling (20-security stage) ------------------------------------

GITLEAKS_PINNED_VERSION="8.30.1"
GITLEAKS_VERSION="${GITLEAKS_VERSION:-${GITLEAKS_PINNED_VERSION}}"
GITLEAKS_SHA256_X64="551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb"
GITLEAKS_SHA256_ARM64="e4a487ee7ccd7d3a7f7ec08657610aa3606637dab924210b3aee62570fb4b080"
GITLEAKS_SHA256_ARMV7="8d39f0d94ba0d774b2282187656fb039a2d82893ec1fd6be7d7121aae759a57d"

SHELLCHECK_PINNED_VERSION="0.11.0"
SHELLCHECK_VERSION="${SHELLCHECK_VERSION:-${SHELLCHECK_PINNED_VERSION}}"
SHELLCHECK_SHA256_X86_64="8c3be12b05d5c177a04c29e3c78ce89ac86f1595681cab149b65b97c4e227198"
SHELLCHECK_SHA256_AARCH64="12b331c1d2db6b9eb13cfca64306b1b157a86eb69db83023e261eaa7e7c14588"
SHELLCHECK_SHA256_ARMV6HF="8afc50b302d5feeac9381ea114d563f0150d061520042b254d6eb715797c8223"

# v2.15.1 also RENAMED the release assets from `hadolint-Linux-x86_64` to
# `hadolint-linux-x86_64` (lower-case "l"). The previous installer resolved
# "latest" and then composed the old capitalised name, so every run since that
# release 404ed on the real latest and silently fell back to its hard-coded
# v2.14.0 -- a pin nobody chose, reached through a failure nobody saw. Pinning
# the version fixes the asset name along with it.
HADOLINT_PINNED_VERSION="2.15.1"
HADOLINT_VERSION="${HADOLINT_VERSION:-${HADOLINT_PINNED_VERSION}}"
HADOLINT_SHA256_X86_64="c7187db94eeeeca956519a6af171adc31453941a1e777961f6e680f697c8c507"
HADOLINT_SHA256_ARM64="f6198ef8090f404dbb771abfee086eb8c48ac177f30da7fd3510aca35b344b5d"

# The CodeQL CLI ships as one ~1 GB bundle. `releases/latest/download/...` was a
# double moving target: a new bundle every few weeks AND no way to state which
# one a given scan used.
CODEQL_BUNDLE_PINNED_VERSION="codeql-bundle-v2.26.3"
CODEQL_BUNDLE_VERSION="${CODEQL_BUNDLE_VERSION:-${CODEQL_BUNDLE_PINNED_VERSION}}"
CODEQL_BUNDLE_SHA256_LINUX64="77e5be1b550d66662e600e795b6cf2ea1729e853e3dc79e02594f767039d2a29"

OSV_SCANNER_PINNED_VERSION="2.5.1"
OSV_SCANNER_VERSION="${OSV_SCANNER_VERSION:-${OSV_SCANNER_PINNED_VERSION}}"
OSV_SCANNER_SHA256_AMD64="f9f25499a2c8cc367b3af45df2ea7eeca7fbccceab9c35079968f4b3652194be"
OSV_SCANNER_SHA256_ARM64="3d0f5aa5a6baa8eb32bcef247388e149ef6030a6634ccae6fa0d62681fb27a6d"

# --- Language tooling --------------------------------------------------------

GOLANGCI_LINT_PINNED_VERSION="2.12.2"
GOLANGCI_LINT_VERSION="${GOLANGCI_LINT_VERSION:-${GOLANGCI_LINT_PINNED_VERSION}}"
GOLANGCI_LINT_SHA256_AMD64="8df580d2670fed8fa984aac0507099af8df275e665215f5c7a2ae3943893a553"
GOLANGCI_LINT_SHA256_ARM64="44cd40a8c76c86755375adfeea52cfd3533cb43d7bd647771e0ae065e166df3a"

PROGUARD_PINNED_VERSION="7.6.1"
PROGUARD_VERSION="${PROGUARD_VERSION:-${PROGUARD_PINNED_VERSION}}"
PROGUARD_SHA256="672ef62a3154474a6172cbfde9a2f09da1642a17a80e1c7b79a6cc58953fbe06"

# GoReleaser is deliberately held at 1.x: the v2 release is a breaking
# configuration change, so bumping it is a migration for every consumer, not a
# version bump. Pinning it here does not decide that migration either way.
GORELEASER_PINNED_VERSION="1.21.2"
GORELEASER_VERSION="${GORELEASER_VERSION:-${GORELEASER_PINNED_VERSION}}"
GORELEASER_SHA256_AMD64_DEB="9b63d670dab507f2b21e811812805f051b720cb781c2b4c3f3c1d656be05c1a6"

# --- Terraform / Terragrunt tooling ------------------------------------------

TFLINT_PINNED_VERSION="0.64.0"
TFLINT_VERSION="${TFLINT_VERSION:-${TFLINT_PINNED_VERSION}}"
TFLINT_SHA256_AMD64="cca9d13e2e1d7a2c627af60ff899a3c9b74212899416aeb96ec764d2ef954537"
TFLINT_SHA256_ARM64="560da89aacf59389d4eb029730dd5b109b7288096c32f2726a0d9e783a5ea8eb"

TERRAGRUNT_PINNED_VERSION="1.1.3"
TERRAGRUNT_VERSION="${TERRAGRUNT_VERSION:-${TERRAGRUNT_PINNED_VERSION}}"
TERRAGRUNT_SHA256_AMD64="d5da6a66741f4ee752aa3b502b57e47fd6d5c178942861b2507f14f083e7606e"
TERRAGRUNT_SHA256_ARM64="5e9b388402ab7075e907e8d8511662e2a828008129746e4e5e23de04c7b78ef4"

# `rios0rios0/terra` is first-party, which changes nothing about the download:
# the templates fetched `install.sh` from the `main` BRANCH and piped it into a
# shell, so a bad commit on that branch reached every consumer's runner
# immediately, with no release and no review gate in between.
TERRA_PINNED_VERSION="1.17.9"
TERRA_VERSION="${TERRA_VERSION:-${TERRA_PINNED_VERSION}}"
TERRA_SHA256_AMD64="747b2dc190f68e91fed837f9a67a78530315489f2deef11a50d87531fb5e674c"
TERRA_SHA256_ARM64="363796d502d110e642576bb37beb918976df63ac537930afed02cc84e1124427"

# --- Deployment tooling (50-deployment stage) --------------------------------

FLYCTL_PINNED_VERSION="0.4.84"
FLYCTL_VERSION="${FLYCTL_VERSION:-${FLYCTL_PINNED_VERSION}}"
FLYCTL_SHA256_X86_64="5faeeb6806b939540619518be530ad4cf9de090eff1e0e44795e3f09c113b5ce"
FLYCTL_SHA256_ARM64="677bfad02ea7e44e0c7ef6d0666babc6daa3d468ce97b44d2451d60e97ba3d58"

# The npm-published deploy clients (`wrangler`, `vercel`, `netlify-cli`) talk to
# a hosted API the vendor versions on their side, so these are the majors this
# repository has verified rather than exact builds. npm resolves the newest
# release within the major, which is what keeps a vendor's API deprecation from
# breaking every consumer at once -- but it does mean an unpinned patch. A
# consumer needing a byte-exact client sets the *_CLI_SPEC variable to an exact
# version.
WRANGLER_CLI_SPEC="${WRANGLER_CLI_SPEC:-wrangler@4}"
VERCEL_CLI_SPEC="${VERCEL_CLI_SPEC:-vercel@59}"
NETLIFY_CLI_SPEC="${NETLIFY_CLI_SPEC:-netlify-cli@27}"

# --- Miscellaneous -----------------------------------------------------------

# GitLab's own secure-files installer, used by the GitLab Go binary delivery
# job. It was fetched from the `main` branch and piped into bash inside the job
# that holds the project's signing material.
SECURE_FILES_INSTALLER_PINNED_VERSION="v0.1.16"
SECURE_FILES_INSTALLER_VERSION="${SECURE_FILES_INSTALLER_VERSION:-${SECURE_FILES_INSTALLER_PINNED_VERSION}}"
SECURE_FILES_INSTALLER_SHA256="735418e1b52e6bc9c211383fb86f91ccc898f87ca4b575832737a84ec8d83a5f"


# stoml publishes no checksum manifest and no linux/arm64 build; the digest
# below was computed from the published amd64 artifact.
STOML_PINNED_VERSION="0.7.1"
STOML_VERSION="${STOML_VERSION:-${STOML_PINNED_VERSION}}"
STOML_SHA256_AMD64="8420ad10d39ca568234186be89a60f8a8ece29bc2a91b4c8ad2e00ef73b626de"

# Go modules installed with `go install`. `@latest` used to be the norm here,
# which means the module proxy chose the version and `go.sum` verification only
# ever proved the bytes matched whatever version it chose -- integrity without
# identity.
GOVULNCHECK_PINNED_VERSION="v1.7.0"
GOVULNCHECK_VERSION="${GOVULNCHECK_VERSION:-${GOVULNCHECK_PINNED_VERSION}}"
GOTESTSUM_PINNED_VERSION="v1.13.0"
GOTESTSUM_VERSION="${GOTESTSUM_VERSION:-${GOTESTSUM_PINNED_VERSION}}"
# gocovmerge has never cut a tagged release; the module proxy's canonical
# identifier for it is this pseudo-version, which is as immutable as a tag.
GOCOVMERGE_PINNED_VERSION="v0.0.0-20160331181800-b5bfa59ec0ad"
GOCOVMERGE_VERSION="${GOCOVMERGE_VERSION:-${GOCOVMERGE_PINNED_VERSION}}"
GOCOVER_COBERTURA_PINNED_VERSION="v1.5.0"
GOCOVER_COBERTURA_VERSION="${GOCOVER_COBERTURA_VERSION:-${GOCOVER_COBERTURA_PINNED_VERSION}}"
GO_JUNIT_REPORT_PINNED_VERSION="v2.1.0"
GO_JUNIT_REPORT_VERSION="${GO_JUNIT_REPORT_VERSION:-${GO_JUNIT_REPORT_PINNED_VERSION}}"
CYCLONEDX_GOMOD_PINNED_VERSION="v1.10.0"
CYCLONEDX_GOMOD_VERSION="${CYCLONEDX_GOMOD_VERSION:-${CYCLONEDX_GOMOD_PINNED_VERSION}}"

# Python and Ruby tools installed from their language registries. Each is the
# version `latest` resolved to when this pin was taken, so pinning changed no
# behaviour on the day it landed -- it only stopped the behaviour changing
# underneath a consumer afterwards.
PDM_SPEC="${PDM_SPEC:-pdm==2.28.1}"
VULTURE_SPEC="${VULTURE_SPEC:-vulture==2.16}"
SEMGREP_SPEC="${SEMGREP_SPEC:-semgrep==1.173.0}"
BUNDLER_AUDIT_SPEC="${BUNDLER_AUDIT_SPEC:-bundler-audit:0.9.3}"
DEBRIDE_SPEC="${DEBRIDE_SPEC:-debride:1.15.2}"
KNIP_SPEC="${KNIP_SPEC:-knip@6.32.2}"
