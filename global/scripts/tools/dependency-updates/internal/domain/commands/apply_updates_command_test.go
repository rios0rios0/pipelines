package commands_test

import (
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/rios0rios0/pipelines/global/scripts/tools/dependency-updates/internal/domain/commands"
	"github.com/rios0rios0/pipelines/global/scripts/tools/dependency-updates/internal/domain/entities"
	"github.com/rios0rios0/pipelines/global/scripts/tools/dependency-updates/internal/domain/repositories"
	"github.com/rios0rios0/pipelines/global/scripts/tools/dependency-updates/internal/test/doubles"
)

const (
	vendoredPath = "global/scripts/languages/golang/golangci-lint/.golangci.yml"
	upstreamBase = "linters:\n  enable:\n    - asasalint\n"
	upstreamNext = "linters:\n  enable:\n    - asasalint\n    - paralleltest\n"
	assetPattern = "https://raw.githubusercontent.com/maratori/golangci-lint-config/v{version}/.golangci.yml"
)

func configFiles() map[string]string {
	files := manifest(
		"# upstream: github-release maratori/golangci-lint-config", "# vendored: "+vendoredPath, "# osv: none",
		`GOLANGCI_LINT_CONFIG_PINNED_VERSION="2.9.0"`,
		"# asset: "+assetPattern,
		`GOLANGCI_LINT_CONFIG_SHA256="`+entities.SHA256Hex([]byte(upstreamBase))+`"`,
	)
	files[vendoredPath] = upstreamBase + "# this repository's adjustment\n"
	return files
}

func configReleases() *doubles.StubReleases {
	return &doubles.StubReleases{
		Latests: map[string]string{"maratori/golangci-lint-config": "v2.14.0"},
		Lists: map[string][]entities.Release{"maratori/golangci-lint-config": {
			{Version: "v2.14.0", Published: daysAgo(20)},
		}},
	}
}

func upstreamFiles() *doubles.StubArtifacts {
	return &doubles.StubArtifacts{Contents: map[string]string{
		entities.Render(assetPattern, "2.9.0"):  upstreamBase,
		entities.Render(assetPattern, "2.14.0"): upstreamNext,
	}}
}

type applyCase struct {
	files     map[string]string
	releases  *doubles.StubReleases
	artifacts *doubles.StubArtifacts
	source    *doubles.StubSource
	merger    *doubles.StubMerger
	scanner   *doubles.StubImageScanner
}

func (c applyCase) run() (commands.ApplyResult, *doubles.InMemoryWorkspace) {
	workspace := doubles.NewInMemoryWorkspace(c.files)
	checker := commands.NewCheckUpdatesCommand(workspace, c.releases, &doubles.StubAdvisories{}, entities.Settings{},
		referenceNow(), 1)
	result := checker.Execute(checker.Discover())
	source := c.source
	if source == nil {
		source = &doubles.StubSource{}
	}
	// A nil stub must reach the command as a nil interface, or it would read as
	// a scanner that is switched on.
	var scanner repositories.ImageScannerRepository
	if c.scanner != nil {
		scanner = c.scanner
	}
	command := commands.NewApplyUpdatesCommand(workspace, c.artifacts, source, c.merger, scanner, 1)
	return command.Execute(result), workspace
}

func TestApplyUpdatesCommandVendored(t *testing.T) {
	t.Parallel()

	t.Run("should re-merge the adjustments onto the new release and bump the pin with its digest", func(t *testing.T) {
		t.Parallel()
		// given
		merger := &doubles.StubMerger{Merged: upstreamNext + "# this repository's adjustment\n"}
		scenario := applyCase{
			files:     configFiles(),
			releases:  configReleases(),
			artifacts: upstreamFiles(),
			merger:    merger,
		}

		// when
		result, workspace := scenario.run()

		// then
		require.Len(t, result.Applied, 1)
		plan := result.Applied[0].Apply
		require.NotNil(t, plan.Vendored)
		assert.Equal(t, []string{"paralleltest"}, plan.Vendored.Enabled)
		assert.Equal(
			t,
			"https://github.com/maratori/golangci-lint-config/compare/v2.9.0...v2.14.0",
			plan.Vendored.CompareURL,
		)
		assert.Equal(t, merger.Merged, workspace.Text(vendoredPath))
		assert.Contains(t, workspace.Text(entities.ManifestPath), `GOLANGCI_LINT_CONFIG_PINNED_VERSION="2.14.0"`)
		assert.Contains(t, workspace.Text(entities.ManifestPath), entities.SHA256Hex([]byte(upstreamNext)))
		require.Len(t, merger.Calls, 1)
		assert.Equal(
			t,
			[3]string{upstreamBase + "# this repository's adjustment\n", upstreamBase, upstreamNext},
			merger.Calls[0],
		)
	})

	t.Run("should refuse a merge that conflicts and leave every file as it was", func(t *testing.T) {
		t.Parallel()
		// given
		scenario := applyCase{
			files: configFiles(), releases: configReleases(), artifacts: upstreamFiles(),
			merger: &doubles.StubMerger{Conflicts: 2},
		}

		// when
		result, workspace := scenario.run()

		// then
		require.Len(t, result.Refused, 1)
		assert.Contains(t, result.Refused[0].Refused, "conflicts with this repository's adjustments in 2 place(s)")
		assert.Equal(t, configFiles()[vendoredPath], workspace.Text(vendoredPath))
		assert.Contains(t, workspace.Text(entities.ManifestPath), `GOLANGCI_LINT_CONFIG_PINNED_VERSION="2.9.0"`)
	})

	t.Run("should refuse when upstream's file is not the one the copy was taken from", func(t *testing.T) {
		t.Parallel()
		// given
		artifacts := upstreamFiles()
		artifacts.Contents[entities.Render(assetPattern, "2.9.0")] = "a re-tagged release\n"
		scenario := applyCase{
			files: configFiles(), releases: configReleases(), artifacts: artifacts, merger: &doubles.StubMerger{},
		}

		// when
		result, _ := scenario.run()

		// then
		require.Len(t, result.Refused, 1)
		assert.Contains(t, result.Refused[0].Refused, "not the file this repository's copy was taken from")
	})

	t.Run("should refuse a release that starts declaring a linter plugin", func(t *testing.T) {
		t.Parallel()
		// given
		artifacts := upstreamFiles()
		artifacts.Contents[entities.Render(assetPattern, "2.14.0")] = upstreamNext + "  settings:\n    custom:\n      x:\n"
		scenario := applyCase{
			files: configFiles(), releases: configReleases(), artifacts: artifacts, merger: &doubles.StubMerger{},
		}

		// when
		result, _ := scenario.run()

		// then
		require.Len(t, result.Refused, 1)
		assert.Contains(t, result.Refused[0].Refused, "custom linter plugin")
	})
}

func TestApplyUpdatesCommandActionHistory(t *testing.T) {
	t.Parallel()

	oldCommit, newCommit := entities.SHA256Hex([]byte("old"))[:40], entities.SHA256Hex([]byte("new"))[:40]
	files := map[string]string{
		".github/workflows/ci.yaml": "      - uses: 'someorg/someaction@" + oldCommit + "' # v3.1.0\n",
	}
	releases := &doubles.StubReleases{
		Latests: map[string]string{"someorg/someaction": "v4.0.0"},
		Lists:   map[string][]entities.Release{"someorg/someaction": {{Version: "v4.0.0", Published: daysAgo(30)}}},
	}
	source := func(status string) *doubles.StubSource {
		return &doubles.StubSource{
			Commits: map[string]string{"someorg/someaction@v4.0.0": newCommit},
			Comparisons: map[string]entities.Comparison{
				"someorg/someaction " + oldCommit + "..." + newCommit: {Status: status, AheadBy: 3, Files: 2},
			},
		}
	}

	t.Run("should re-pin an action whose release commit descends from the pinned one", func(t *testing.T) {
		t.Parallel()
		// given
		scenario := applyCase{files: files, releases: releases, source: source("ahead"), merger: &doubles.StubMerger{}}

		// when
		result, workspace := scenario.run()

		// then
		require.Len(t, result.Applied, 1)
		require.NotNil(t, result.Applied[0].Apply.History)
		assert.Equal(t, 3, result.Applied[0].Apply.History.AheadBy)
		assert.Contains(t, workspace.Text(".github/workflows/ci.yaml"), newCommit+"' # v4.0.0")
	})

	t.Run("should refuse a release commit outside the pinned commit's history", func(t *testing.T) {
		t.Parallel()
		// given
		scenario := applyCase{
			files:    files,
			releases: releases,
			source:   source("diverged"),
			merger:   &doubles.StubMerger{},
		}

		// when
		result, workspace := scenario.run()

		// then
		require.Len(t, result.Refused, 1)
		assert.Contains(t, result.Refused[0].Refused, "does not descend from the pinned")
		assert.Contains(t, workspace.Text(".github/workflows/ci.yaml"), oldCommit+"' # v3.1.0")
	})
}

func TestApplyUpdatesCommandImageScan(t *testing.T) {
	t.Parallel()

	oldReference := "someimage:1.0@sha256:" + strings.Repeat("a", 64)
	newReference := "someimage:1.0@sha256:" + strings.Repeat("c", 64)
	files := map[string]string{".github/workflows/ci.yaml": "    container:\n      image: '" + oldReference + "'\n"}
	releases := &doubles.StubReleases{Latests: map[string]string{oldReference: "sha256:" + strings.Repeat("c", 64)}}

	t.Run("should refuse a rebuild that introduces a known vulnerability, keeping the old pin", func(t *testing.T) {
		t.Parallel()
		// given
		scenario := applyCase{files: files, releases: releases, merger: &doubles.StubMerger{},
			scanner: &doubles.StubImageScanner{Scans: map[string]entities.ImageScan{
				oldReference: {},
				newReference: {Findings: []entities.ImageFinding{finding("glibc", "CVE-2026-9", "CRITICAL")}},
			}}}

		// when
		result, workspace := scenario.run()

		// then
		require.Len(t, result.Refused, 1)
		assert.Contains(t, result.Refused[0].Refused, "the rebuild introduces glibc 1 CVE-2026-9 (CRITICAL)")
		assert.Contains(t, workspace.Text(".github/workflows/ci.yaml"), oldReference)
	})

	t.Run("should re-pin a rebuild that introduces nothing and record what it fixes", func(t *testing.T) {
		t.Parallel()
		// given
		scenario := applyCase{files: files, releases: releases, merger: &doubles.StubMerger{},
			scanner: &doubles.StubImageScanner{Scans: map[string]entities.ImageScan{
				oldReference: {Findings: []entities.ImageFinding{finding("openssl", "CVE-2026-1", "HIGH")}},
				newReference: {},
			}}}

		// when
		result, workspace := scenario.run()

		// then
		require.Len(t, result.Applied, 1)
		require.NotNil(t, result.Applied[0].Apply.Image)
		assert.Len(t, result.Applied[0].Apply.Image.Fixed, 1)
		assert.Contains(t, workspace.Text(".github/workflows/ci.yaml"), newReference)
	})
}
