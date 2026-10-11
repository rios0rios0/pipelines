package commands_test

import (
	"errors"
	"maps"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/rios0rios0/pipelines/global/scripts/tools/dependency-updates/internal/domain/commands"
	"github.com/rios0rios0/pipelines/global/scripts/tools/dependency-updates/internal/domain/entities"
	"github.com/rios0rios0/pipelines/global/scripts/tools/dependency-updates/internal/domain/repositories"
	"github.com/rios0rios0/pipelines/global/scripts/tools/dependency-updates/internal/test/doubles"
)

func referenceNow() time.Time {
	return time.Date(2026, 10, 10, 6, 0, 0, 0, time.UTC)
}

func daysAgo(days int) time.Time {
	return referenceNow().Add(-time.Duration(days) * entities.Day)
}

func manifest(lines ...string) map[string]string {
	return map[string]string{entities.ManifestPath: strings.Join(lines, "\n") + "\n"}
}

func goTool(advisoryRanges ...entities.RangeEvent) entities.Advisory {
	return entities.Advisory{ID: "GO-2026-1", Severity: "HIGH", Affected: []entities.AffectedPackage{{
		Package: entities.Package{Ecosystem: entities.EcosystemGo, Name: "example.com/tool"},
		Ranges:  []entities.AffectedRange{{Type: entities.RangeEcosystem, Events: advisoryRanges}},
	}}}
}

func toolManifest() map[string]string {
	return manifest(
		"# upstream: github-release example/tool",
		"# osv: Go example.com/tool",
		`TOOL_PINNED_VERSION="1.2.3"`,
	)
}

// goWorkflow is where the Go fixtures write their copies of the Go pin.
const goWorkflow = ".github/workflows/ci.yaml"

func goDigest(character string) string {
	return "sha256:" + strings.Repeat(character, 64)
}

// goPinned is a repository pinning Go at `release` on the 1.27 line, with a
// `go-version:` input naming `input` and a container running `image`.
func goPinned(release, input, image string) map[string]string {
	files := manifest(
		"# upstream: go-toolchain golang.org/toolchain track=1.27",
		"# osv: Go stdlib toolchain",
		`GO_PINNED_VERSION="`+release+`"`,
	)
	files[goWorkflow] = "        with:\n          go-version: '" + input + "'\n" +
		"    container:\n      image: '" + image + "'\n"
	return files
}

// goReleases answer Go 1.27.2, published nine days ago, and the digest every
// image name in `digests` resolves to.
func goReleases(digests map[string]string) *doubles.StubReleases {
	latests := map[string]string{"golang.org/toolchain": "1.27.2"}
	maps.Copy(latests, digests)
	return &doubles.StubReleases{
		Latests: latests,
		Lists: map[string][]entities.Release{"golang.org/toolchain": {
			{Version: "1.27.2", Published: daysAgo(9)}, {Version: "1.27.1", Published: daysAgo(43)},
		}},
	}
}

// goAdvisories are one standard-library and one `go` command advisory, both
// fixed in Go 1.27.2: the two packages the Go vulnerability database files the
// toolchain's issues under.
func goAdvisories() []entities.Advisory {
	advisory := func(identifier, pkg string) entities.Advisory {
		return entities.Advisory{ID: identifier, Severity: "HIGH", Affected: []entities.AffectedPackage{{
			Package: entities.Package{Ecosystem: entities.EcosystemGo, Name: pkg},
			Ranges: []entities.AffectedRange{{Type: entities.RangeEcosystem, Events: []entities.RangeEvent{
				{Introduced: "0"}, {Fixed: "1.27.2"},
			}}},
		}}}
	}
	return []entities.Advisory{advisory("GO-2026-6603", "stdlib"), advisory("GO-2026-6601", "toolchain")}
}

func labelled(t *testing.T, tasks []*entities.Task, label string) *entities.Task {
	t.Helper()
	for _, task := range tasks {
		if task.Label == label {
			return task
		}
	}
	require.Failf(t, "no task", "no task is labelled %s", label)
	return nil
}

func check(
	files map[string]string,
	releases *doubles.StubReleases,
	advisories *doubles.StubAdvisories,
) commands.CheckResult {
	command := commands.NewCheckUpdatesCommand(doubles.NewInMemoryWorkspace(files), releases, advisories,
		entities.Settings{}, referenceNow(), 1)
	return command.Execute(command.Discover())
}

func onlyTask(t *testing.T, result commands.CheckResult) *entities.Task {
	t.Helper()
	require.Len(t, result.Tasks, 1)
	return result.Tasks[0]
}

func TestCheckUpdatesCommand(t *testing.T) {
	t.Parallel()

	t.Run("should propose the newest release past the cooldown and hold the younger one", func(t *testing.T) {
		t.Parallel()
		// given
		releases := &doubles.StubReleases{
			Latests: map[string]string{"example/tool": "v1.4.0"},
			Lists: map[string][]entities.Release{"example/tool": {
				{Version: "v1.4.0", Published: daysAgo(2)}, {Version: "v1.3.0", Published: daysAgo(10)},
			}},
		}

		// when
		task := onlyTask(t, check(toolManifest(), releases, &doubles.StubAdvisories{}))

		// then
		assert.True(t, task.Outdated)
		assert.Equal(t, "1.3.0", task.Proposed())
		require.NotNil(t, task.Selection.Held)
		assert.Equal(t, "v1.4.0", task.Selection.Held.Version)
	})

	t.Run("should force the fix of a known vulnerability with the cooldown waived", func(t *testing.T) {
		t.Parallel()
		// given
		releases := &doubles.StubReleases{
			Latests: map[string]string{"example/tool": "v1.4.0"},
			Lists: map[string][]entities.Release{"example/tool": {
				{Version: "v1.4.0", Published: daysAgo(1)}, {Version: "v1.3.0", Published: daysAgo(10)},
			}},
		}
		advisories := &doubles.StubAdvisories{Advisories: []entities.Advisory{
			goTool(entities.RangeEvent{Introduced: "0"}, entities.RangeEvent{Fixed: "1.4.0"}),
		}}

		// when
		result := check(toolManifest(), releases, advisories)

		// then
		task := onlyTask(t, result)
		assert.True(t, task.IsVulnerable())
		assert.Equal(t, "1.4.0", task.Proposed())
		assert.True(t, task.Selection.Waived)
		assert.Equal(t, []string{"GO-2026-1"}, entities.AdvisoryIDs(task.Selection.Fixed))
		assert.Len(t, result.Vulnerable(), 1)
	})

	t.Run("should never propose a release that introduces a known vulnerability", func(t *testing.T) {
		t.Parallel()
		// given
		releases := &doubles.StubReleases{
			Latests: map[string]string{"example/tool": "v1.4.0"},
			Lists: map[string][]entities.Release{"example/tool": {
				{Version: "v1.4.0", Published: daysAgo(20)}, {Version: "v1.3.0", Published: daysAgo(30)},
			}},
		}
		advisories := &doubles.StubAdvisories{Advisories: []entities.Advisory{
			goTool(entities.RangeEvent{Introduced: "1.4.0"}),
		}}

		// when
		task := onlyTask(t, check(toolManifest(), releases, advisories))

		// then
		assert.Equal(t, "1.3.0", task.Proposed())
		require.Len(t, task.Selection.Rejected, 1)
		assert.Equal(t, "v1.4.0", task.Selection.Rejected[0].Version)
	})

	t.Run("should report a binary with no advisory source as untracked", func(t *testing.T) {
		t.Parallel()
		// given
		files := manifest("# upstream: github-release example/tool", `TOOL_PINNED_VERSION="1.2.3"`,
			"# upstream: pypi pdm", `PDM_SPEC="${PDM_SPEC:-pdm==2.29.2}"`)
		command := commands.NewCheckUpdatesCommand(doubles.NewInMemoryWorkspace(files), &doubles.StubReleases{},
			&doubles.StubAdvisories{}, entities.Settings{}, referenceNow(), 1)

		// when
		result := command.Discover()

		// then
		require.Len(t, result.Untracked, 1)
		assert.Equal(t, "TOOL", result.Untracked[0].Name)
		assert.Equal(t, "osv", result.Untracked[0].Missing)
	})

	t.Run("should never move a pin past its ceiling", func(t *testing.T) {
		t.Parallel()
		// given
		files := manifest(
			"# upstream: github-release golangci/golangci-lint", "# osv: none", `GOLANGCI_LINT_PINNED_VERSION="2.10.0"`,
			"# upstream: github-release maratori/golangci-lint-config ceiling=GOLANGCI_LINT", "# osv: none",
			`GOLANGCI_LINT_CONFIG_PINNED_VERSION="2.9.0"`,
		)
		releases := &doubles.StubReleases{
			Latests: map[string]string{"golangci/golangci-lint": "v2.10.0", "maratori/golangci-lint-config": "v2.14.0"},
			Lists: map[string][]entities.Release{"maratori/golangci-lint-config": {
				{Version: "v2.14.0", Published: daysAgo(20)}, {Version: "v2.10.0", Published: daysAgo(40)},
				{Version: "v2.9.0", Published: daysAgo(60)},
			}},
		}

		// when
		result := check(files, releases, &doubles.StubAdvisories{})

		// then
		config := result.Tasks[1]
		assert.Equal(t, "v2.10.0", config.Latest)
		assert.Equal(t, "2.10.0", config.Proposed())
	})

	t.Run("should report an advisory database it could not reach", func(t *testing.T) {
		t.Parallel()
		// given
		releases := &doubles.StubReleases{Latests: map[string]string{"example/tool": "v1.2.3"}}

		// when
		result := check(toolManifest(), releases, &doubles.StubAdvisories{Err: errors.New("osv.dev unreachable")})

		// then
		assert.Equal(t, "osv.dev unreachable", result.AdvisoryError)
	})

	t.Run("should move a range pin without a cooldown, since npm resolves it at run time", func(t *testing.T) {
		t.Parallel()
		// given
		files := manifest("# upstream: npm wrangler", `WRANGLER_CLI_SPEC="${WRANGLER_CLI_SPEC:-wrangler@4}"`)
		releases := &doubles.StubReleases{Latests: map[string]string{"wrangler": "5.1.0"}}

		// when
		task := onlyTask(t, check(files, releases, &doubles.StubAdvisories{}))

		// then
		assert.Equal(t, "5", task.Proposed())
		assert.False(t, task.Security.Checked, "the newest 4.x is not known without the full package history")
	})

	t.Run("should report nothing to do when every pin is current", func(t *testing.T) {
		t.Parallel()
		// given
		releases := &doubles.StubReleases{Latests: map[string]string{"example/tool": "v1.2.3"}}

		// when
		result := check(toolManifest(), releases, &doubles.StubAdvisories{})

		// then
		assert.Empty(t, result.Outdated())
		assert.Empty(t, result.Proposals())
		assert.Empty(t, result.Vulnerable())
	})
}

func TestCheckUpdatesCommandGoToolchain(t *testing.T) {
	t.Parallel()

	oldImage := "golang:1.27.1-bookworm@" + goDigest("a")

	t.Run("should force the Go fix of an issue in the standard library or the go command alike", func(t *testing.T) {
		t.Parallel()
		// given
		releases := goReleases(map[string]string{oldImage: goDigest("a"), "golang:1.27.2-bookworm": goDigest("c")})

		// when
		result := check(goPinned("1.27.1", "1.27.1", oldImage), releases,
			&doubles.StubAdvisories{Advisories: goAdvisories()})

		// then
		pin := labelled(t, result.Tasks, "GO")
		assert.Equal(t, []string{"GO-2026-6603", "GO-2026-6601"}, entities.AdvisoryIDs(pin.Security.Current))
		assert.Equal(t, "1.27.2", pin.Proposed())
		assert.Len(t, pin.Selection.Fixed, 2)
	})

	t.Run("should move a golang image to the tag of the release its pin proposes", func(t *testing.T) {
		t.Parallel()
		// given
		releases := goReleases(map[string]string{oldImage: goDigest("a"), "golang:1.27.2-bookworm": goDigest("c")})

		// when
		result := check(goPinned("1.27.1", "1.27.1", oldImage), releases, &doubles.StubAdvisories{})

		// then
		image := labelled(t, result.Tasks, "golang:1.27.1-bookworm")
		assert.Equal(t, "golang:1.27.2-bookworm", image.Retag)
		assert.Equal(t, goDigest("c"), image.Target(), "the digest the NEW tag resolves to")
		assert.Contains(t, result.Proposals(), image)
	})

	t.Run("should move an image left behind its pin even when the pin itself moves nowhere", func(t *testing.T) {
		t.Parallel()
		// given
		releases := goReleases(map[string]string{oldImage: goDigest("a"), "golang:1.27.2-bookworm": goDigest("c")})

		// when
		result := check(goPinned("1.27.2", "1.27.2", oldImage), releases, &doubles.StubAdvisories{})

		// then
		assert.False(t, labelled(t, result.Tasks, "GO").Outdated)
		assert.Equal(t, "golang:1.27.2-bookworm", labelled(t, result.Tasks, "golang:1.27.1-bookworm").Retag)
		require.Len(t, result.Drift, 1)
		assert.Equal(t, "golang:1.27.1-bookworm", result.Drift[0].Inline)
	})

	t.Run("should hand a person an image whose variant is not published for the release", func(t *testing.T) {
		t.Parallel()
		// given
		alpine := "golang:1.27.1-alpine3.24@" + goDigest("a")
		releases := goReleases(map[string]string{alpine: goDigest("a")})
		releases.Errors = map[string]error{
			"golang:1.27.2-alpine3.24": repositories.NewNotFoundError("golang:1.27.2-alpine3.24 -> HTTP 404"),
		}

		// when
		result := check(goPinned("1.27.1", "1.27.1", alpine), releases, &doubles.StubAdvisories{})

		// then
		image := labelled(t, result.Tasks, "golang:1.27.1-alpine3.24")
		assert.Contains(t, image.Refused, "the registry has no `golang:1.27.2-alpine3.24`")
		assert.Empty(t, image.Error, "a tag that does not exist is an answer, not a failed lookup")
		assert.NotContains(t, result.Proposals(), image)
		assert.Equal(t, []*entities.Task{image}, result.Refused())
	})
}
