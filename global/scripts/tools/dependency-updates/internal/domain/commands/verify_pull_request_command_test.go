package commands_test

import (
	"maps"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/rios0rios0/pipelines/global/scripts/tools/dependency-updates/internal/domain/commands"
	"github.com/rios0rios0/pipelines/global/scripts/tools/dependency-updates/internal/domain/entities"
	"github.com/rios0rios0/pipelines/global/scripts/tools/dependency-updates/internal/domain/repositories"
	"github.com/rios0rios0/pipelines/global/scripts/tools/dependency-updates/internal/test/doubles"
)

const toolAsset = "https://github.com/example/tool/releases/download/v{version}/tool_{version}_linux_amd64.tar.gz"

func toolPin(version, digest string) map[string]string {
	return manifest(
		"# upstream: github-release example/tool",
		"# osv: Go example.com/tool",
		`TOOL_PINNED_VERSION="`+version+`"`,
		"# asset: "+toolAsset,
		`TOOL_SHA256_AMD64="`+digest+`"`,
	)
}

type verifyCase struct {
	base, head map[string]string
	releases   *doubles.StubReleases
	advisories []entities.Advisory
	// unreachable is the advisory database's answer to every lookup, when set.
	unreachable error
	artifacts   *doubles.StubArtifacts
	source      *doubles.StubSource
	images      *doubles.StubImages
	merger      *doubles.StubMerger
	scanner     *doubles.StubImageScanner
}

func (c verifyCase) run() commands.VerifyResult {
	orEmpty := func(artifacts *doubles.StubArtifacts) *doubles.StubArtifacts {
		if artifacts == nil {
			return &doubles.StubArtifacts{}
		}
		return artifacts
	}
	source, images, merger := c.source, c.images, c.merger
	if source == nil {
		source = &doubles.StubSource{}
	}
	if images == nil {
		images = &doubles.StubImages{}
	}
	if merger == nil {
		merger = &doubles.StubMerger{}
	}
	return commands.NewVerifyPullRequestCommand(commands.VerifyDependencies{
		Base: doubles.NewInMemoryWorkspace(c.base), Head: doubles.NewInMemoryWorkspace(c.head),
		Releases: c.releases, Advisories: &doubles.StubAdvisories{Advisories: c.advisories, Err: c.unreachable},
		Artifacts: orEmpty(c.artifacts), Source: source, Images: images, Merger: merger,
		Scanner: scannerOf(c.scanner),
		Now:     referenceNow(), Jobs: 1,
	}).Execute()
}

func findingOf(t *testing.T, change commands.VerifiedChange, check string) commands.Finding {
	t.Helper()
	for _, finding := range change.Findings {
		if finding.Check == check {
			return finding
		}
	}
	require.Failf(t, "no finding", "%s has no %s finding: %+v", change.Label, check, change.Findings)
	return commands.Finding{}
}

func toolBump(published int) verifyCase {
	newDigest := entities.SHA256Hex([]byte("tool 1.3.0"))
	return verifyCase{
		base: toolPin("1.2.3", entities.SHA256Hex([]byte("tool 1.2.3"))),
		head: toolPin("1.3.0", newDigest),
		releases: &doubles.StubReleases{Lists: map[string][]entities.Release{"example/tool": {
			{Version: "v1.3.0", Published: daysAgo(published)},
		}}},
		artifacts: &doubles.StubArtifacts{Digests: map[string]string{entities.Render(toolAsset, "1.3.0"): newDigest}},
	}
}

func TestVerifyPullRequestCommandManifest(t *testing.T) {
	t.Parallel()

	t.Run("should verify a clean bump of an aged release whose digest matches upstream", func(t *testing.T) {
		t.Parallel()
		// given
		scenario := toolBump(30)

		// when
		result := scenario.run()

		// then
		require.Len(t, result.Changes, 1)
		assert.Equal(t, commands.VerdictPass, result.Changes[0].Verdict(), "%+v", result.Changes[0].Findings)
		assert.Zero(t, result.Exit())
	})

	t.Run("should fail a bump to a version with an advisory the old one did not have", func(t *testing.T) {
		t.Parallel()
		// given
		scenario := toolBump(30)
		scenario.advisories = []entities.Advisory{goTool(entities.RangeEvent{Introduced: "1.3.0"})}

		// when
		result := scenario.run()

		// then
		finding := findingOf(t, result.Changes[0], commands.CheckAdvisories)
		assert.Equal(t, commands.VerdictFail, finding.Verdict)
		assert.Contains(t, finding.Detail, "GO-2026-1")
		assert.Equal(t, 1, result.Exit())
	})

	t.Run("should fail a release younger than the cooldown", func(t *testing.T) {
		t.Parallel()
		// given
		scenario := toolBump(2)

		// when
		result := scenario.run()

		// then
		finding := findingOf(t, result.Changes[0], commands.CheckCooldown)
		assert.Equal(t, commands.VerdictFail, finding.Verdict)
		assert.Contains(t, finding.Detail, "7 days")
	})

	t.Run("should waive the cooldown for a release that fixes a known vulnerability", func(t *testing.T) {
		t.Parallel()
		// given
		scenario := toolBump(2)
		scenario.advisories = []entities.Advisory{
			goTool(entities.RangeEvent{Introduced: "0"}, entities.RangeEvent{Fixed: "1.3.0"}),
		}

		// when
		result := scenario.run()

		// then
		finding := findingOf(t, result.Changes[0], commands.CheckCooldown)
		assert.Equal(t, commands.VerdictPass, finding.Verdict)
		assert.Contains(t, finding.Detail, "waived")
		assert.Equal(t, commands.VerdictPass, findingOf(t, result.Changes[0], commands.CheckAdvisories).Verdict)
	})

	t.Run("should fail a digest that is not what upstream serves", func(t *testing.T) {
		t.Parallel()
		// given
		scenario := toolBump(30)
		scenario.artifacts.Digests[entities.Render(toolAsset, "1.3.0")] = entities.SHA256Hex([]byte("tampered"))

		// when
		result := scenario.run()

		// then
		finding := findingOf(t, result.Changes[0], commands.CheckIntegrity)
		assert.Equal(t, commands.VerdictFail, finding.Verdict)
		assert.Contains(t, finding.Detail, "committed")
	})

	t.Run("should verify nothing, and ask nothing, when no pin moves", func(t *testing.T) {
		t.Parallel()
		// given
		pins := toolPin("1.2.3", entities.SHA256Hex([]byte("tool 1.2.3")))
		scenario := verifyCase{
			base: pins, head: maps.Clone(pins), releases: &doubles.StubReleases{},
			unreachable: repositories.NewLookupError("api.osv.dev -> HTTP 503"),
		}

		// when
		result := scenario.run()

		// then
		assert.Empty(t, result.Changes)
		assert.Empty(t, result.AdvisoryError, "a pull request that moves no pin must not depend on the database")
		assert.Zero(t, result.Exit())
	})

	t.Run("should fail closed when a pin moves and the database cannot be consulted", func(t *testing.T) {
		t.Parallel()
		// given
		scenario := toolBump(30)
		scenario.unreachable = repositories.NewLookupError("api.osv.dev -> HTTP 503")

		// when
		result := scenario.run()

		// then
		assert.Contains(t, result.AdvisoryError, "HTTP 503")
		assert.Equal(t, 2, result.Exit())
	})
}

func TestVerifyPullRequestCommandVendored(t *testing.T) {
	t.Parallel()

	head := func(text string) map[string]string {
		files := manifest(
			"# upstream: github-release maratori/golangci-lint-config", "# vendored: "+vendoredPath, "# osv: none",
			`GOLANGCI_LINT_CONFIG_PINNED_VERSION="2.14.0"`, "# asset: "+assetPattern,
			`GOLANGCI_LINT_CONFIG_SHA256="`+entities.SHA256Hex([]byte(upstreamNext))+`"`,
		)
		files[vendoredPath] = text
		return files
	}
	scenario := func(headText string) verifyCase {
		artifacts := upstreamFiles()
		artifacts.Digests = map[string]string{
			entities.Render(assetPattern, "2.14.0"): entities.SHA256Hex([]byte(upstreamNext)),
		}
		return verifyCase{
			base: configFiles(), head: head(headText), releases: configReleases(), artifacts: artifacts,
			merger: &doubles.StubMerger{Merged: "upstream 2.14.0 with the adjustments\n"},
		}
	}

	t.Run(
		"should verify a vendored file that is exactly upstream's change merged onto the adjustments",
		func(t *testing.T) {
			t.Parallel()
			// given
			bump := scenario("upstream 2.14.0 with the adjustments\n")

			// when
			result := bump.run()

			// then
			finding := findingOf(t, result.Changes[0], commands.CheckVendored)
			assert.Equal(t, commands.VerdictPass, finding.Verdict, finding.Detail)
			assert.Contains(t, finding.Detail, "paralleltest")
			assert.Zero(t, result.Exit())
		},
	)

	t.Run("should fail a vendored file carrying edits the bump does not explain", func(t *testing.T) {
		t.Parallel()
		// given
		bump := scenario("upstream 2.14.0 with the adjustments\nand a quiet extra rule\n")

		// when
		result := bump.run()

		// then
		finding := findingOf(t, result.Changes[0], commands.CheckVendored)
		assert.Equal(t, commands.VerdictFail, finding.Verdict)
		assert.Contains(t, finding.Detail, "edits the version bump does not explain")
	})
}

func TestVerifyPullRequestCommandActions(t *testing.T) {
	t.Parallel()

	oldCommit, newCommit := strings.Repeat("1", 40), strings.Repeat("8", 40)
	workflow := func(sha, version string) map[string]string {
		return map[string]string{
			".github/workflows/ci.yaml": "      - uses: 'someorg/someaction@" + sha + "' # " + version + "\n",
		}
	}
	scenario := func(tagCommit, status string) verifyCase {
		return verifyCase{
			base: workflow(oldCommit, "v3.1.0"), head: workflow(newCommit, "v4.0.0"),
			releases: &doubles.StubReleases{Lists: map[string][]entities.Release{"someorg/someaction": {
				{Version: "v4.0.0", Published: daysAgo(30)},
			}}},
			source: &doubles.StubSource{
				Commits: map[string]string{"someorg/someaction@v4.0.0": tagCommit},
				Comparisons: map[string]entities.Comparison{
					"someorg/someaction " + oldCommit + "..." + newCommit: {Status: status, AheadBy: 4, Files: 3},
				},
			},
		}
	}

	t.Run("should verify an action pinned to its tag's commit that descends from the old pin", func(t *testing.T) {
		t.Parallel()
		// given
		bump := scenario(newCommit, "ahead")

		// when
		result := bump.run()

		// then
		require.Len(t, result.Changes, 1)
		assert.Equal(t, commands.VerdictPass, result.Changes[0].Verdict(), "%+v", result.Changes[0].Findings)
	})

	t.Run("should fail a pin that is not the commit its comment names", func(t *testing.T) {
		t.Parallel()
		// given
		bump := scenario(strings.Repeat("9", 40), "ahead")

		// when
		result := bump.run()

		// then
		finding := findingOf(t, result.Changes[0], commands.CheckProvenance)
		assert.Equal(t, commands.VerdictFail, finding.Verdict)
		assert.Contains(t, finding.Detail, "not the release it claims to be")
	})

	t.Run("should fail a commit outside the old pin's history", func(t *testing.T) {
		t.Parallel()
		// given
		bump := scenario(newCommit, "diverged")

		// when
		result := bump.run()

		// then
		assert.Equal(t, commands.VerdictFail, findingOf(t, result.Changes[0], commands.CheckHistory).Verdict)
	})

	t.Run("should warn about an action nothing was pinned to before", func(t *testing.T) {
		t.Parallel()
		// given
		bump := scenario(newCommit, "ahead")
		bump.base = map[string]string{}

		// when
		result := bump.run()

		// then
		assert.Equal(t, commands.VerdictWarn, findingOf(t, result.Changes[0], commands.CheckHistory).Verdict)
		assert.Zero(t, result.Exit(), "a warning is for a reviewer, not a failure")
	})
}

// scannerOf hands a nil stub to the command as a nil interface: image scanning
// switched off.
func scannerOf(stub *doubles.StubImageScanner) repositories.ImageScannerRepository {
	if stub == nil {
		return nil
	}
	return stub
}

func finding(pkg, identifier, severity string) entities.ImageFinding {
	return entities.ImageFinding{
		Package:   pkg,
		Version:   "1",
		Ecosystem: "Debian:13",
		IDs:       []string{identifier},
		Severity:  severity,
	}
}

func TestVerifyPullRequestCommandImages(t *testing.T) {
	t.Parallel()

	oldReference := "python:3.13-slim@sha256:" + strings.Repeat("a", 64)
	newReference := "python:3.13-slim@sha256:" + strings.Repeat("c", 64)
	files := func(ref string) map[string]string {
		return map[string]string{"containers/Dockerfile": "FROM " + ref + "\n"}
	}
	rebuild := func(scans map[string]entities.ImageScan) verifyCase {
		return verifyCase{
			base:     files(oldReference),
			head:     files(newReference),
			releases: &doubles.StubReleases{},
			images:   &doubles.StubImages{Existing: []string{newReference}},
			scanner:  &doubles.StubImageScanner{Scans: scans},
		}
	}

	t.Run("should fail a digest the named repository does not hold", func(t *testing.T) {
		t.Parallel()
		// given
		scenario := rebuild(nil)
		scenario.images = &doubles.StubImages{}

		// when
		result := scenario.run()

		// then
		assert.Equal(t, commands.VerdictFail, findingOf(t, result.Changes[0], commands.CheckRegistry).Verdict)
	})

	t.Run("should verify a rebuild that introduces nothing and say what it fixes", func(t *testing.T) {
		t.Parallel()
		// given
		scenario := rebuild(map[string]entities.ImageScan{
			oldReference: {
				Findings: []entities.ImageFinding{
					finding("openssl", "CVE-2026-1", "HIGH"),
					finding("apt", "CVE-2011-3374", "LOW"),
				},
			},
			newReference: {Findings: []entities.ImageFinding{finding("apt", "CVE-2011-3374", "LOW")}},
		})

		// when
		result := scenario.run()

		// then
		scan := findingOf(t, result.Changes[0], commands.CheckScan)
		assert.Equal(t, commands.VerdictPass, scan.Verdict)
		assert.Contains(t, scan.Detail, "it fixes 1: openssl 1 CVE-2026-1 (HIGH)")
		assert.Zero(t, result.Exit())
	})

	t.Run("should fail a rebuild that introduces a known vulnerability", func(t *testing.T) {
		t.Parallel()
		// given
		scenario := rebuild(map[string]entities.ImageScan{
			oldReference: {},
			newReference: {Findings: []entities.ImageFinding{finding("glibc", "CVE-2026-9", "CRITICAL")}},
		})

		// when
		result := scenario.run()

		// then
		scan := findingOf(t, result.Changes[0], commands.CheckScan)
		assert.Equal(t, commands.VerdictFail, scan.Verdict)
		assert.Contains(t, scan.Detail, "the rebuild introduces glibc 1 CVE-2026-9 (CRITICAL)")
		assert.Equal(t, 1, result.Exit())
	})

	t.Run("should say a Windows image was not scanned rather than call it clean", func(t *testing.T) {
		t.Parallel()
		// given
		scenario := rebuild(map[string]entities.ImageScan{
			oldReference: {Skipped: "it publishes no linux/amd64 image"},
			newReference: {Skipped: "it publishes no linux/amd64 image"},
		})

		// when
		result := scenario.run()

		// then
		scan := findingOf(t, result.Changes[0], commands.CheckScan)
		assert.Equal(t, commands.VerdictWarn, scan.Verdict)
		assert.Contains(t, scan.Detail, "not scanned: it publishes no linux/amd64 image")
	})

	t.Run("should fail closed when an image cannot be scanned", func(t *testing.T) {
		t.Parallel()
		// given
		scenario := rebuild(map[string]entities.ImageScan{})

		// when
		result := scenario.run()

		// then
		assert.Equal(t, commands.VerdictError, findingOf(t, result.Changes[0], commands.CheckScan).Verdict)
		assert.Equal(t, 2, result.Exit())
	})

	t.Run("should list what a new image carries for its reviewer", func(t *testing.T) {
		t.Parallel()
		// given
		scenario := rebuild(map[string]entities.ImageScan{
			newReference: {Findings: []entities.ImageFinding{finding("openssl", "CVE-2026-1", "HIGH")}},
		})
		scenario.base = map[string]string{}

		// when
		result := scenario.run()

		// then
		scan := findingOf(t, result.Changes[0], commands.CheckScan)
		assert.Equal(t, commands.VerdictWarn, scan.Verdict)
		assert.Contains(t, scan.Detail, "review it as a new dependency")
	})

	t.Run("should report image scanning switched off", func(t *testing.T) {
		t.Parallel()
		// given
		scenario := rebuild(nil)
		scenario.scanner = nil

		// when
		result := scenario.run()

		// then
		assert.Equal(t, commands.VerdictWarn, findingOf(t, result.Changes[0], commands.CheckScan).Verdict)
	})
}

func TestVerifyPullRequestCommandGoToolchain(t *testing.T) {
	t.Parallel()

	oldImage := "golang:1.27.1-bookworm@" + goDigest("a")
	newImage := "golang:1.27.2-bookworm@" + goDigest("c")
	bump := func(input, image string) verifyCase {
		return verifyCase{
			base:       goPinned("1.27.1", "1.27.1", oldImage),
			head:       goPinned("1.27.2", input, image),
			releases:   goReleases(nil),
			advisories: goAdvisories(),
			images:     &doubles.StubImages{Existing: []string{image}},
			scanner: &doubles.StubImageScanner{Scans: map[string]entities.ImageScan{
				oldImage: {Findings: []entities.ImageFinding{finding("stdlib", "GO-2026-6603", "HIGH")}},
				image:    {},
			}},
		}
	}
	imageChange := func(t *testing.T, result commands.VerifyResult) commands.VerifiedChange {
		t.Helper()
		for _, change := range result.Changes {
			if change.Group == entities.GroupImage {
				return change
			}
		}
		require.Fail(t, "no image change")
		return commands.VerifiedChange{}
	}

	t.Run("should verify a Go bump that takes its inputs and images with it", func(t *testing.T) {
		t.Parallel()
		// given
		scenario := bump("1.27.2", newImage)

		// when
		result := scenario.run()

		// then
		assert.Zero(t, result.Exit(), "%+v", result.Changes)
		image := imageChange(t, result)
		assert.Equal(t, "golang:1.27.1-bookworm", image.Retagged)
		assert.Contains(t, findingOf(t, image, commands.CheckScan).Detail, "it fixes 1")
		assert.Equal(t, commands.VerdictPass, findingOf(t, image, commands.CheckCopies).Verdict)
		assert.Contains(t, findingOf(t, result.Changes[0], commands.CheckAdvisories).Detail, "GO-2026-6601")
		assert.Empty(t, result.Drift)
	})

	t.Run("should fail a Go bump that leaves an input behind", func(t *testing.T) {
		t.Parallel()
		// given
		scenario := bump("1.27.1", newImage)

		// when
		result := scenario.run()

		// then
		assert.Equal(t, 1, result.Exit())
		assert.Equal(t, []entities.Drift{
			{Name: "GO_PINNED_VERSION", File: goWorkflow, Inline: "1.27.1", Manifest: "1.27.2"},
		}, result.Drift)
	})

	t.Run("should fail an image moved to another release than its pin names", func(t *testing.T) {
		t.Parallel()
		// given
		scenario := bump("1.27.2", "golang:1.27.3-bookworm@"+goDigest("e"))

		// when
		result := scenario.run()

		// then
		finding := findingOf(t, imageChange(t, result), commands.CheckCopies)
		assert.Equal(t, commands.VerdictFail, finding.Verdict)
		assert.Contains(t, finding.Detail, "names Go `1.27.3`, but `GO` pins `1.27.2`")
	})

	t.Run("should fail a copy edited away from its pin without asking the network", func(t *testing.T) {
		t.Parallel()
		// given
		scenario := verifyCase{
			base:        goPinned("1.27.2", "1.27.2", newImage),
			head:        goPinned("1.27.2", "1.27.1", newImage),
			releases:    &doubles.StubReleases{},
			unreachable: repositories.NewLookupError("api.osv.dev -> HTTP 503"),
		}

		// when
		result := scenario.run()

		// then
		assert.Empty(t, result.Changes)
		assert.Empty(t, result.AdvisoryError)
		assert.Len(t, result.Drift, 1)
		assert.Equal(t, 1, result.Exit())
	})
}
