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
# THE `# upstream:` ANNOTATIONS
#
# Every pin below carries one, and it is what lets
# `global/scripts/tools/dependency-updates/` tell you when the pin is stale --
# pinning stops a dependency moving without a decision, and the annotation is
# how the decision gets prompted. The shape is:
#
#   # upstream: <kind> <coordinate> [track=<major>]
#
#   kind         one of github-release, github-tag, gitlab-tag, pypi, npm,
#                rubygems, goproxy
#   coordinate   owner/repo, a project path, or a package/module name
#   track=<n>    only report releases INSIDE major <n>. Used where a pin is
#                deliberately held back: GoReleaser is on 1.x because 2.x is a
#                breaking configuration change, so reporting 2.x every run would
#                be reporting a migration as an update until somebody muted the
#                check.
#
# A pin with NO annotation is reported as untracked and fails the check, rather
# than being skipped quietly -- otherwise coverage shrinks one forgotten
# annotation at a time while the job stays green.
#
# THE `# asset:` AND `# checksums:` ANNOTATIONS
#
# A digest describes one file, so bumping a version means re-deriving every
# digest beside it. These two annotations are what let that be done by the
# scheduled workflow rather than by hand:
#
#   # checksums: <url>    under `# upstream:` -- the publisher's checksum
#                         manifest, where the release ships one
#   # asset: <url>        above each *_SHA256* -- the file that digest is of
#
# Both are URLs with `{version}` standing for the pin's value, written exactly
# as the installer composes its download, so reviewing one against the other is
# a matter of reading two lines. A new digest is taken from the asset of the new
# version and must match the checksum manifest when one is named. Before that,
# the template has to reproduce the digest committed here for the CURRENT
# version, which is what proves it names the file the installer really fetches
# -- a template that has drifted from its installer refuses the bump instead of
# writing a digest of the wrong file. A digest with no `# asset:` is reported as
# untracked, for the same reason a pin with no `# upstream:` is.
#
# After editing an annotation, check every template against its committed
# digest (network):
#
#   ./global/scripts/tools/dependency-updates/run.sh --verify-assets
#
# HOW TO BUMP A TOOL
#
# The scheduled `dependency-updates.yaml` workflow does this twice a week and
# opens a pull request with the result; `make apply-dependency-updates` does the
# same in a working tree. By hand:
#
#   1. Change the *_VERSION value.
#   2. Replace every *_SHA256_* value for that tool. Take them from the
#      upstream checksum manifest; do not carry an old digest forward.
#   3. Run `make test-supply-chain`, which re-asserts the shape of every entry.
#
# `make check-dependency-updates` reports which of them currently have a newer
# release without changing anything.
#
# Each version is overridable from the environment so an operator can respond to
# an upstream CVE without waiting for a release here. Overriding the version
# WITHOUT also supplying the matching checksum is refused by
# `verify-download.sh` rather than silently downgraded to an unverified
# download -- see `download_verified` for how to opt out deliberately.

# --- Security tooling (20-security stage) ------------------------------------

# upstream: github-release gitleaks/gitleaks
# checksums: https://github.com/gitleaks/gitleaks/releases/download/v{version}/gitleaks_{version}_checksums.txt
GITLEAKS_PINNED_VERSION="8.30.1"
GITLEAKS_VERSION="${GITLEAKS_VERSION:-${GITLEAKS_PINNED_VERSION}}"
# asset: https://github.com/gitleaks/gitleaks/releases/download/v{version}/gitleaks_{version}_linux_x64.tar.gz
GITLEAKS_SHA256_X64="551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb"
# asset: https://github.com/gitleaks/gitleaks/releases/download/v{version}/gitleaks_{version}_linux_arm64.tar.gz
GITLEAKS_SHA256_ARM64="e4a487ee7ccd7d3a7f7ec08657610aa3606637dab924210b3aee62570fb4b080"
# asset: https://github.com/gitleaks/gitleaks/releases/download/v{version}/gitleaks_{version}_linux_armv7.tar.gz
GITLEAKS_SHA256_ARMV7="8d39f0d94ba0d774b2282187656fb039a2d82893ec1fd6be7d7121aae759a57d"

# ShellCheck publishes no checksum manifest, so its digests rest on the asset
# alone.
# upstream: github-release koalaman/shellcheck
SHELLCHECK_PINNED_VERSION="0.11.0"
SHELLCHECK_VERSION="${SHELLCHECK_VERSION:-${SHELLCHECK_PINNED_VERSION}}"
# asset: https://github.com/koalaman/shellcheck/releases/download/v{version}/shellcheck-v{version}.linux.x86_64.tar.xz
SHELLCHECK_SHA256_X86_64="8c3be12b05d5c177a04c29e3c78ce89ac86f1595681cab149b65b97c4e227198"
# asset: https://github.com/koalaman/shellcheck/releases/download/v{version}/shellcheck-v{version}.linux.aarch64.tar.xz
SHELLCHECK_SHA256_AARCH64="12b331c1d2db6b9eb13cfca64306b1b157a86eb69db83023e261eaa7e7c14588"
# asset: https://github.com/koalaman/shellcheck/releases/download/v{version}/shellcheck-v{version}.linux.armv6hf.tar.xz
SHELLCHECK_SHA256_ARMV6HF="8afc50b302d5feeac9381ea114d563f0150d061520042b254d6eb715797c8223"

# v2.15.1 also RENAMED the release assets from `hadolint-Linux-x86_64` to
# `hadolint-linux-x86_64` (lower-case "l"). The previous installer resolved
# "latest" and then composed the old capitalised name, so every run since that
# release 404ed on the real latest and silently fell back to its hard-coded
# v2.14.0 -- a pin nobody chose, reached through a failure nobody saw. Pinning
# the version fixes the asset name along with it.
# upstream: github-release hadolint/hadolint
# checksums: https://github.com/hadolint/hadolint/releases/download/v{version}/checksums.sha256
HADOLINT_PINNED_VERSION="2.15.1"
HADOLINT_VERSION="${HADOLINT_VERSION:-${HADOLINT_PINNED_VERSION}}"
# asset: https://github.com/hadolint/hadolint/releases/download/v{version}/hadolint-linux-x86_64
HADOLINT_SHA256_X86_64="c7187db94eeeeca956519a6af171adc31453941a1e777961f6e680f697c8c507"
# asset: https://github.com/hadolint/hadolint/releases/download/v{version}/hadolint-linux-arm64
HADOLINT_SHA256_ARM64="f6198ef8090f404dbb771abfee086eb8c48ac177f30da7fd3510aca35b344b5d"

# The CodeQL CLI ships as one ~1 GB bundle. `releases/latest/download/...` was a
# double moving target: a new bundle every few weeks AND no way to state which
# one a given scan used. The same repository also releases the CodeQL ACTION
# (`v4.x`), which is why the checker compares tags within one release line --
# the bundle is only ever moved to another `codeql-bundle-v*` release.
# upstream: github-release github/codeql-action
# checksums: https://github.com/github/codeql-action/releases/download/{version}/codeql-bundle-linux64.tar.gz.checksum.txt
CODEQL_BUNDLE_PINNED_VERSION="codeql-bundle-v2.26.4"
CODEQL_BUNDLE_VERSION="${CODEQL_BUNDLE_VERSION:-${CODEQL_BUNDLE_PINNED_VERSION}}"
# asset: https://github.com/github/codeql-action/releases/download/{version}/codeql-bundle-linux64.tar.gz
CODEQL_BUNDLE_SHA256_LINUX64="48e1ab8b874d57bd6fd7c90fefee75addc5a45e9bd063982df9beb45a62dd5d3"

# upstream: github-release google/osv-scanner
# checksums: https://github.com/google/osv-scanner/releases/download/v{version}/osv-scanner_SHA256SUMS
OSV_SCANNER_PINNED_VERSION="2.5.1"
OSV_SCANNER_VERSION="${OSV_SCANNER_VERSION:-${OSV_SCANNER_PINNED_VERSION}}"
# asset: https://github.com/google/osv-scanner/releases/download/v{version}/osv-scanner_linux_amd64
OSV_SCANNER_SHA256_AMD64="f9f25499a2c8cc367b3af45df2ea7eeca7fbccceab9c35079968f4b3652194be"
# asset: https://github.com/google/osv-scanner/releases/download/v{version}/osv-scanner_linux_arm64
OSV_SCANNER_SHA256_ARM64="3d0f5aa5a6baa8eb32bcef247388e149ef6030a6634ccae6fa0d62681fb27a6d"

# --- Language tooling --------------------------------------------------------

# upstream: github-release golangci/golangci-lint
# checksums: https://github.com/golangci/golangci-lint/releases/download/v{version}/golangci-lint-{version}-checksums.txt
GOLANGCI_LINT_PINNED_VERSION="2.13.2"
GOLANGCI_LINT_VERSION="${GOLANGCI_LINT_VERSION:-${GOLANGCI_LINT_PINNED_VERSION}}"
# asset: https://github.com/golangci/golangci-lint/releases/download/v{version}/golangci-lint-{version}-linux-amd64.tar.gz
GOLANGCI_LINT_SHA256_AMD64="2277d43b98ec0054280f2ac26b53268bae97682444678a59a657dd565da021d6"
# asset: https://github.com/golangci/golangci-lint/releases/download/v{version}/golangci-lint-{version}-linux-arm64.tar.gz
GOLANGCI_LINT_SHA256_ARM64="a2a4e0065aa41be71f7c5ac90f271b61751331e5d04314e62afe4027855f0893"

# Guardsquare publishes no checksum manifest, so this digest rests on the asset
# alone.
# upstream: github-release Guardsquare/proguard
PROGUARD_PINNED_VERSION="7.10.0"
PROGUARD_VERSION="${PROGUARD_VERSION:-${PROGUARD_PINNED_VERSION}}"
# asset: https://github.com/Guardsquare/proguard/releases/download/v{version}/proguard-{version}.tar.gz
PROGUARD_SHA256="fbff4dfe037d0724ff767ad555c06ebd14063ccf99a657cf05a69e6f2610da21"

# GoReleaser is deliberately held at 1.x: the v2 release is a breaking
# configuration change, so bumping it is a migration for every consumer, not a
# version bump. Pinning it here does not decide that migration either way.
# upstream: github-release goreleaser/goreleaser track=1
# checksums: https://github.com/goreleaser/goreleaser/releases/download/v{version}/checksums.txt
GORELEASER_PINNED_VERSION="1.26.2"
GORELEASER_VERSION="${GORELEASER_VERSION:-${GORELEASER_PINNED_VERSION}}"
# asset: https://github.com/goreleaser/goreleaser/releases/download/v{version}/goreleaser_{version}_amd64.deb
GORELEASER_SHA256_AMD64_DEB="2710e9740185be82b6929c78b695b455a09975e231bddbb8e295f1cc1b591d4b"

# --- Terraform / Terragrunt tooling ------------------------------------------

# upstream: github-release terraform-linters/tflint
# checksums: https://github.com/terraform-linters/tflint/releases/download/v{version}/checksums.txt
TFLINT_PINNED_VERSION="0.64.0"
TFLINT_VERSION="${TFLINT_VERSION:-${TFLINT_PINNED_VERSION}}"
# asset: https://github.com/terraform-linters/tflint/releases/download/v{version}/tflint_linux_amd64.zip
TFLINT_SHA256_AMD64="cca9d13e2e1d7a2c627af60ff899a3c9b74212899416aeb96ec764d2ef954537"
# asset: https://github.com/terraform-linters/tflint/releases/download/v{version}/tflint_linux_arm64.zip
TFLINT_SHA256_ARM64="560da89aacf59389d4eb029730dd5b109b7288096c32f2726a0d9e783a5ea8eb"

# upstream: github-release gruntwork-io/terragrunt
# checksums: https://github.com/gruntwork-io/terragrunt/releases/download/v{version}/SHA256SUMS
TERRAGRUNT_PINNED_VERSION="1.1.4"
TERRAGRUNT_VERSION="${TERRAGRUNT_VERSION:-${TERRAGRUNT_PINNED_VERSION}}"
# asset: https://github.com/gruntwork-io/terragrunt/releases/download/v{version}/terragrunt_linux_amd64
TERRAGRUNT_SHA256_AMD64="a2640da8455fa5f3671167e6373832b0907b9dc972dd01c2093cc7808934e158"
# asset: https://github.com/gruntwork-io/terragrunt/releases/download/v{version}/terragrunt_linux_arm64
TERRAGRUNT_SHA256_ARM64="c65d1897446590ebb3c695835cc956c12c5374a9add8312517c83c9fd7a1c06b"

# `rios0rios0/terra` is first-party, which changes nothing about the download:
# the templates fetched `install.sh` from the `main` BRANCH and piped it into a
# shell, so a bad commit on that branch reached every consumer's runner
# immediately, with no release and no review gate in between.
# upstream: github-release rios0rios0/terra
# checksums: https://github.com/rios0rios0/terra/releases/download/{version}/checksums.txt
TERRA_PINNED_VERSION="1.18.6"
TERRA_VERSION="${TERRA_VERSION:-${TERRA_PINNED_VERSION}}"
# asset: https://github.com/rios0rios0/terra/releases/download/{version}/terra-{version}-linux-amd64.tar.gz
TERRA_SHA256_AMD64="45f3577ea372ddd1f2ab9ead67c184cda3a9baf75977e383b4912e12778eb2f2"
# asset: https://github.com/rios0rios0/terra/releases/download/{version}/terra-{version}-linux-arm64.tar.gz
TERRA_SHA256_ARM64="9f154449271b0f23dc1147c80f48012c46cdf0c08809d60b3f1331771de4fd72"

# --- Deployment tooling (50-deployment stage) --------------------------------

# upstream: github-release superfly/flyctl
# checksums: https://github.com/superfly/flyctl/releases/download/v{version}/flyctl_{version}_checksums.txt
FLYCTL_PINNED_VERSION="0.4.99"
FLYCTL_VERSION="${FLYCTL_VERSION:-${FLYCTL_PINNED_VERSION}}"
# asset: https://github.com/superfly/flyctl/releases/download/v{version}/flyctl_{version}_Linux_x86_64.tar.gz
FLYCTL_SHA256_X86_64="384a14958b214b18ebda784dee101a633ceae626ac4bcccee0fc7ebb111247a4"
# asset: https://github.com/superfly/flyctl/releases/download/v{version}/flyctl_{version}_Linux_arm64.tar.gz
FLYCTL_SHA256_ARM64="23fcf016fb7812b743674ee06167abbd68ffb74e00f61c45b7e213f0bd4694ab"

# mikefarah/yq, resolved by global/scripts/shared/resolve-yq.sh for the
# golangci-lint config merge. Four digests rather than the usual two because
# this is the one tool here resolved on macOS as well: `resolve_yq` runs from a
# developer's `make lint` as readily as from a runner, and the kislyuk `yq` that
# makes the resolution necessary is just as likely to be the one Homebrew or pip
# put on a Mac.
#
# The digest suffix carries the OS as well as the arch (`LINUX_AMD64`, not
# `AMD64`) because it names the release asset, and mikefarah publishes one
# asset per OS/arch pair: `yq_linux_amd64`, `yq_darwin_arm64`, and so on.
#
# Verified against the `checksums` file published with the release, whose
# SHA-256 lives in the column named by `checksums_hashes_order` -- the file
# carries 31 hashes per asset and no header, so reading the wrong column yields
# a plausible-looking digest that matches nothing. The automated bump reads the
# `checksums-bsd` file from the same release instead, which names each
# algorithm on its own line (`SHA256 (yq_linux_amd64) = ...`), so there is no
# column to get wrong.
# upstream: github-release mikefarah/yq
# checksums: https://github.com/mikefarah/yq/releases/download/v{version}/checksums-bsd
YQ_PINNED_VERSION="4.53.6"
YQ_VERSION="${YQ_VERSION:-${YQ_PINNED_VERSION}}"
# asset: https://github.com/mikefarah/yq/releases/download/v{version}/yq_linux_amd64
YQ_SHA256_LINUX_AMD64="c5f056448f973ae7d39b5401949648a78f2dc1947d6a8eb65be60d5c504b9385"
# asset: https://github.com/mikefarah/yq/releases/download/v{version}/yq_linux_arm64
YQ_SHA256_LINUX_ARM64="88a1016bc1d657375a35864e4f44b6f333df8ff97b559f51bba0adcb2169df09"
# asset: https://github.com/mikefarah/yq/releases/download/v{version}/yq_darwin_amd64
YQ_SHA256_DARWIN_AMD64="caa513cb04f3804b34d4752f0e0d7904fecb9e7cf1d34081289f83259319a7f6"
# asset: https://github.com/mikefarah/yq/releases/download/v{version}/yq_darwin_arm64
YQ_SHA256_DARWIN_ARM64="cceb0b8d71ea5294334121f8429f33f92b920e7217d904a2f9f35443968ac424"

# The npm-published deploy clients (`wrangler`, `vercel`, `netlify-cli`) talk to
# a hosted API the vendor versions on their side, so these are the majors this
# repository has verified rather than exact builds. npm resolves the newest
# release within the major, which is what keeps a vendor's API deprecation from
# breaking every consumer at once -- but it does mean an unpinned patch. A
# consumer needing a byte-exact client sets the *_CLI_SPEC variable to an exact
# version.
# upstream: npm wrangler
WRANGLER_CLI_SPEC="${WRANGLER_CLI_SPEC:-wrangler@4}"
# upstream: npm vercel
VERCEL_CLI_SPEC="${VERCEL_CLI_SPEC:-vercel@59}"
# upstream: npm netlify-cli
NETLIFY_CLI_SPEC="${NETLIFY_CLI_SPEC:-netlify-cli@27}"

# --- Miscellaneous -----------------------------------------------------------

# GitLab's own secure-files installer, used by the GitLab Go binary delivery
# job. It was fetched from the `main` branch and piped into bash inside the job
# that holds the project's signing material.
# upstream: gitlab-tag gitlab-org/incubation-engineering/mobile-devops/download-secure-files
SECURE_FILES_INSTALLER_PINNED_VERSION="v0.1.16"
SECURE_FILES_INSTALLER_VERSION="${SECURE_FILES_INSTALLER_VERSION:-${SECURE_FILES_INSTALLER_PINNED_VERSION}}"
# asset: https://gitlab.com/gitlab-org/incubation-engineering/mobile-devops/download-secure-files/-/raw/{version}/installer
SECURE_FILES_INSTALLER_SHA256="735418e1b52e6bc9c211383fb86f91ccc898f87ca4b575832737a84ec8d83a5f"


# stoml publishes no checksum manifest and no linux/arm64 build; the digest
# below was computed from the published amd64 artifact.
# upstream: github-release freshautomations/stoml
STOML_PINNED_VERSION="0.7.1"
STOML_VERSION="${STOML_VERSION:-${STOML_PINNED_VERSION}}"
# asset: https://github.com/freshautomations/stoml/releases/download/v{version}/stoml_linux_amd64
STOML_SHA256_AMD64="8420ad10d39ca568234186be89a60f8a8ece29bc2a91b4c8ad2e00ef73b626de"

# Go modules installed with `go install`. `@latest` used to be the norm here,
# which means the module proxy chose the version and `go.sum` verification only
# ever proved the bytes matched whatever version it chose -- integrity without
# identity.
# upstream: goproxy golang.org/x/vuln
GOVULNCHECK_PINNED_VERSION="v1.8.0"
GOVULNCHECK_VERSION="${GOVULNCHECK_VERSION:-${GOVULNCHECK_PINNED_VERSION}}"
# upstream: goproxy gotest.tools/gotestsum
GOTESTSUM_PINNED_VERSION="v1.13.0"
GOTESTSUM_VERSION="${GOTESTSUM_VERSION:-${GOTESTSUM_PINNED_VERSION}}"
# gocovmerge has never cut a tagged release; the module proxy's canonical
# identifier for it is this pseudo-version, which is as immutable as a tag.
# upstream: goproxy github.com/wadey/gocovmerge
GOCOVMERGE_PINNED_VERSION="v0.0.0-20160331181800-b5bfa59ec0ad"
GOCOVMERGE_VERSION="${GOCOVMERGE_VERSION:-${GOCOVMERGE_PINNED_VERSION}}"
# upstream: goproxy github.com/boumenot/gocover-cobertura
GOCOVER_COBERTURA_PINNED_VERSION="v1.5.0"
GOCOVER_COBERTURA_VERSION="${GOCOVER_COBERTURA_VERSION:-${GOCOVER_COBERTURA_PINNED_VERSION}}"
# upstream: goproxy github.com/jstemmer/go-junit-report/v2
GO_JUNIT_REPORT_PINNED_VERSION="v2.1.0"
GO_JUNIT_REPORT_VERSION="${GO_JUNIT_REPORT_VERSION:-${GO_JUNIT_REPORT_PINNED_VERSION}}"
# upstream: goproxy github.com/CycloneDX/cyclonedx-gomod
CYCLONEDX_GOMOD_PINNED_VERSION="v1.12.0"
CYCLONEDX_GOMOD_VERSION="${CYCLONEDX_GOMOD_VERSION:-${CYCLONEDX_GOMOD_PINNED_VERSION}}"

# Python and Ruby tools installed from their language registries.
#
# The pip call sites all pass `--only-binary :all:`. Installing from a source
# distribution executes that package's `setup.py` AS PART OF THE INSTALL, so an
# sdist is arbitrary code execution on the runner before the tool has even been
# invoked -- the same class of exposure as an npm `postinstall`. Every pin below
# was checked to resolve binary-only INCLUDING its full transitive tree, so the
# flag costs nothing today; if a future bump cannot resolve, that is a signal
# worth reading rather than a flag worth dropping. Each is the
# version `latest` resolved to when this pin was taken, so pinning changed no
# behaviour on the day it landed -- it only stopped the behaviour changing
# underneath a consumer afterwards.
# upstream: pypi pdm
PDM_SPEC="${PDM_SPEC:-pdm==2.29.0}"
# upstream: pypi vulture
VULTURE_SPEC="${VULTURE_SPEC:-vulture==2.16}"
# upstream: pypi semgrep
SEMGREP_SPEC="${SEMGREP_SPEC:-semgrep==1.176.1}"
# upstream: rubygems bundler-audit
BUNDLER_AUDIT_SPEC="${BUNDLER_AUDIT_SPEC:-bundler-audit:0.9.3}"
# upstream: rubygems debride
DEBRIDE_SPEC="${DEBRIDE_SPEC:-debride:1.15.2}"
# upstream: npm knip
KNIP_SPEC="${KNIP_SPEC:-knip@6.34.0}"
