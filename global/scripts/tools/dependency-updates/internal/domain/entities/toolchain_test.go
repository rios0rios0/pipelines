package entities_test

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/rios0rios0/pipelines/global/scripts/tools/dependency-updates/internal/domain/entities"
)

// goManifest pins Go on two release lines, as this repository does.
func goManifest(current, previous string) []entities.ManifestEntry {
	return entities.ParseManifest("# upstream: go-toolchain golang.org/toolchain track=1.27\n" +
		"# osv: Go stdlib toolchain\n" +
		"GO_PINNED_VERSION=\"" + current + "\"\n" +
		"# upstream: go-toolchain golang.org/toolchain track=1.26\n" +
		"# osv: Go stdlib toolchain\n" +
		"GO_1_26_PINNED_VERSION=\"" + previous + "\"\n" +
		"# upstream: pypi pdm\n" +
		"PDM_SPEC=\"${PDM_SPEC:-pdm==2.29.2}\"\n")
}

func TestParseGoImage(t *testing.T) {
	t.Parallel()

	t.Run("should read the release and the variant a golang tag names, digest aside", func(t *testing.T) {
		t.Parallel()
		// given / when
		debian, debianFound := entities.ParseGoImage("golang:1.27.1-bookworm@sha256:" + sha("a"))
		alpine, alpineFound := entities.ParseGoImage("golang:1.27.1-alpine3.24")
		plain, plainFound := entities.ParseGoImage("golang:1.26.6")

		// then
		require.True(t, debianFound)
		require.True(t, alpineFound)
		require.True(t, plainFound)
		assert.Equal(t, entities.GoImage{Release: "1.27.1", Variant: "-bookworm"}, debian)
		assert.Equal(t, "golang:1.27.2-alpine3.24", alpine.Name("1.27.2"))
		assert.Equal(t, "1.26", plain.Line())
	})

	t.Run("should not read a rolling tag or another repository as a Go release", func(t *testing.T) {
		t.Parallel()
		// given
		references := []string{
			"golang:1.27-bookworm",
			"golang:latest",
			"golang:bookworm",
			"ghcr.io/rios0rios0/pipelines/golang:1.26-awscli",
			"mirror.example/golang:1.27.1",
			"python:3.13-slim",
		}

		for _, reference := range references {
			// when
			_, found := entities.ParseGoImage(reference)

			// then
			assert.False(t, found, reference)
		}
	})
}

func TestGoPin(t *testing.T) {
	t.Parallel()

	t.Run("should follow the pin of the copy's own release line", func(t *testing.T) {
		t.Parallel()
		// given
		manifest := goManifest("1.27.2", "1.26.9")

		// when
		current, rangeLike, previous := entities.GoPin(manifest, "1.27.1"), entities.GoPin(manifest, "1.27"),
			entities.GoPin(manifest, "1.26.6")

		// then
		require.NotNil(t, current)
		require.NotNil(t, rangeLike)
		require.NotNil(t, previous)
		assert.Equal(t, "GO", current.Name)
		assert.Equal(t, "GO", rangeLike.Name)
		assert.Equal(t, "GO_1_26", previous.Name)
	})

	t.Run("should find no pin for a line nothing holds", func(t *testing.T) {
		t.Parallel()
		// given
		manifest := goManifest("1.27.2", "1.26.9")

		// when
		pin := entities.GoPin(manifest, "1.25.3")

		// then
		assert.Nil(t, pin)
	})
}

func TestFindGoDrift(t *testing.T) {
	t.Parallel()

	workflow := "      - uses: 'actions/setup-go@" + sha("1")[:40] + "' # v6.0.0\n" +
		"        with:\n          go-version: '1.27.1'\n" +
		"    container:\n      image: 'golang:1.25.3@sha256:" + sha("b") + "'\n"
	azure := "  - task: 'GoTool@0'\n    inputs:\n      version: '1.27.2'\n      architecture: 'amd64'\n" +
		"  - task: 'NodeTool@0'\n    inputs:\n      versionSpec: '22.x'\n"
	dockerfile := "FROM golang:1.26.6-alpine3.24@sha256:" + sha("c") + " AS builder\n"
	files := []entities.SourceText{
		{Path: ".github/workflows/ci.yaml", Text: workflow},
		{Path: "azure-devops/golang/abstracts/go.yaml", Text: azure},
		{Path: "global/containers/tool/Dockerfile", Text: dockerfile, Dockerfile: true},
	}

	t.Run("should report every copy behind its pin, and one no pin holds the line of", func(t *testing.T) {
		t.Parallel()
		// given
		manifest := goManifest("1.27.2", "1.26.9")

		// when
		drift := entities.FindGoDrift(files, manifest)

		// then
		assert.ElementsMatch(t, []entities.Drift{
			{Name: "GO_PINNED_VERSION", File: ".github/workflows/ci.yaml", Inline: "1.27.1", Manifest: "1.27.2"},
			{Name: "go-toolchain", File: ".github/workflows/ci.yaml", Inline: "golang:1.25.3",
				Manifest: "no pin on the 1.25 line"},
			{Name: "GO_1_26_PINNED_VERSION", File: "global/containers/tool/Dockerfile",
				Inline: "golang:1.26.6-alpine3.24", Manifest: "1.26.9"},
		}, drift)
	})

	t.Run("should judge nothing in a repository that pins no Go, as no consumer does", func(t *testing.T) {
		t.Parallel()
		// given
		manifest := entities.ParseManifest("# upstream: pypi pdm\nPDM_SPEC=\"${PDM_SPEC:-pdm==2.29.2}\"\n")

		// when
		drift := entities.FindGoDrift(files, manifest)

		// then
		assert.Empty(t, drift)
	})
}

func TestAlignGoCopies(t *testing.T) {
	t.Parallel()

	t.Run("should move every Go input to its pin's new release, written in full", func(t *testing.T) {
		t.Parallel()
		// given
		manifest := goManifest("1.27.1", "1.26.6")
		targets := map[string]string{"GO_PINNED_VERSION": "1.27.2", "GO_1_26_PINNED_VERSION": "1.26.9"}
		text := "        with:\n          go-version: '1.27.1'\n" +
			"          - task: 'GoTool@0'\n            displayName: 'Use Go'\n            inputs:\n" +
			"              version: '1.27'\n" +
			"  - task: GoTool@0\n    inputs:\n      version: '1.26.6'\n" +
			"  - task: 'NodeTool@0'\n    inputs:\n      version: '1.27.1'\n"

		// when
		aligned, changes := entities.AlignGoCopies(text, "pipeline.yaml", manifest, targets)

		// then
		assert.Contains(t, aligned, "go-version: '1.27.2'")
		assert.Contains(t, aligned, "              version: '1.27.2'")
		assert.Contains(t, aligned, "      version: '1.26.9'")
		assert.Contains(t, aligned, "'NodeTool@0'\n    inputs:\n      version: '1.27.1'",
			"another task's input is not Go's")
		require.Len(t, changes, 3)
		drifted := map[string]bool{}
		for _, change := range changes {
			drifted[change.From] = change.Drifted
		}
		assert.Equal(t, map[string]bool{"1.27.1": false, "1.27": true, "1.26.6": false}, drifted,
			"`1.27` names no release, so it was out of step before this run")
	})
}
