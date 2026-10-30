package entities_test

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/rios0rios0/pipelines/global/scripts/tools/dependency-updates/internal/domain/entities"
)

func TestFindDrift(t *testing.T) {
	t.Parallel()

	t.Run("should read each package of one pip install against its own pin", func(t *testing.T) {
		t.Parallel()
		// given
		files := []entities.SourceText{{
			Path: "action.yaml",
			Text: `python -m pip install --only-binary :all: "pdm==2.29.2" "unearth==0.18.2"` + "\n",
		}}
		expected := map[string]string{"PDM_SPEC": "2.29.2", "UNEARTH_SPEC": "0.18.3"}

		// when
		drifts := entities.FindDrift(files, expected)

		// then
		require.Len(t, drifts, 1)
		assert.Equal(t, "UNEARTH_SPEC", drifts[0].Name)
		assert.Equal(t, "0.18.2", drifts[0].Inline)
		assert.Equal(t, "0.18.3", drifts[0].Manifest)
	})

	t.Run("should report nothing when every copy agrees with its pin", func(t *testing.T) {
		t.Parallel()
		// given
		files := []entities.SourceText{{
			Path: "Dockerfile",
			Text: `RUN pip install --only-binary :all: "pdm==2.29.2" "unearth==0.18.3"` + "\n",
		}}
		expected := map[string]string{"PDM_SPEC": "2.29.2", "UNEARTH_SPEC": "0.18.3"}

		// when
		drifts := entities.FindDrift(files, expected)

		// then
		assert.Empty(t, drifts)
	})

	t.Run("should read a UseNode@1 version and its step name against the Node pin, never a range", func(t *testing.T) {
		t.Parallel()
		// given
		files := []entities.SourceText{{
			Path: "corepack-node-no-cache.yaml",
			Text: "steps:\n  - task: 'UseNode@1'\n    inputs:\n      version: '24.22.0'\n" +
				"    displayName: 'Use Node.js 24.22.0'\n" +
				"  - task: 'NodeTool@0'\n    inputs:\n      versionSpec: '22.x'\n",
		}}
		expected := map[string]string{"NODE_PINNED_VERSION": "24.22.1"}

		// when
		drifts := entities.FindDrift(files, expected)

		// then
		require.Len(t, drifts, 2)
		for _, drift := range drifts {
			assert.Equal(t, "NODE_PINNED_VERSION", drift.Name)
			assert.Equal(t, "24.22.0", drift.Inline)
			assert.Equal(t, "24.22.1", drift.Manifest)
		}
	})
}

func TestScanImages(t *testing.T) {
	t.Parallel()

	t.Run("should read an image in every form the supply-chain suite holds to a digest", func(t *testing.T) {
		t.Parallel()
		// given
		text := "scalar:\n  image: 'scalar:1@sha256:" + sha("a") + "'\n" +
			"listed:\n  - image: 'listed:1@sha256:" + sha("b") + "'\n" +
			"block:\n  image:\n    name: 'block:1@sha256:" + sha("c") + "'\n    entrypoint: ['']\n" +
			"listed-block:\n  - image:  # the runner\n\n      name: 'listed-block:1@sha256:" + sha("d") + "'\n" +
			"    alias: 'runner'\n" +
			"flow:\n  image: { entrypoint: [''], name: 'flow:1@sha256:" + sha("e") + "' }\n" +
			"listed-flow:\n  - image: {name: 'listed-flow:1@sha256:" + sha("f") + "', docker: {user: 'node'}}\n"
		found := map[string]string{}

		// when
		entities.ScanImages(text, false, found)

		// then
		assert.Equal(t, map[string]string{
			"scalar:1@sha256:" + sha("a"):       "sha256:" + sha("a"),
			"listed:1@sha256:" + sha("b"):       "sha256:" + sha("b"),
			"block:1@sha256:" + sha("c"):        "sha256:" + sha("c"),
			"listed-block:1@sha256:" + sha("d"): "sha256:" + sha("d"),
			"flow:1@sha256:" + sha("e"):         "sha256:" + sha("e"),
			"listed-flow:1@sha256:" + sha("f"):  "sha256:" + sha("f"),
		}, found)
	})

	t.Run("should read only the name the image mapping itself holds", func(t *testing.T) {
		t.Parallel()
		// given
		text := "job:\n  image:\n    docker:\n      name: 'nested:1@sha256:" + sha("a") + "'\n" +
			"    name: 'own:1@sha256:" + sha("b") + "'\n" +
			"  steps:\n    - name: 'step:1@sha256:" + sha("c") + "'\n" +
			"inputs:\n  image:\n    description: 'the image to run'\n  name: 'sibling:1@sha256:" + sha("d") + "'\n"
		found := map[string]string{}

		// when
		entities.ScanImages(text, false, found)

		// then
		assert.Equal(t, map[string]string{"own:1@sha256:" + sha("b"): "sha256:" + sha("b")}, found)
	})

	t.Run("should ignore an image that names no digest", func(t *testing.T) {
		t.Parallel()
		// given
		text := "a:\n  image:\n    name: 'node:18'\nb:\n  image: { name: 'node:18' }\nc:\n  image: 'node:18'\n"
		found := map[string]string{}

		// when
		entities.ScanImages(text, false, found)

		// then
		assert.Empty(t, found)
	})

	t.Run("should read a Dockerfile for FROM alone", func(t *testing.T) {
		t.Parallel()
		// given
		text := "FROM base:1@sha256:" + sha("a") + " AS build\n" +
			"RUN printf '%s' \"image: 'yaml:1@sha256:" + sha("b") + "'\"\n"
		found := map[string]string{}

		// when
		entities.ScanImages(text, true, found)

		// then
		assert.Equal(t, map[string]string{"base:1@sha256:" + sha("a"): "sha256:" + sha("a")}, found)
	})
}
