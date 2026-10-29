package main

import (
	"testing"

	"github.com/stretchr/testify/assert"
)

// runsOnInputs declares `runs_on` the way every workflow must, plus the given extra inputs.
func runsOnInputs(extra string) string {
	return "on:\n  workflow_call:\n    inputs:\n      runs_on:\n        required: false\n" +
		"        default: '[\"ubuntu-latest\"]'\n" + extra
}

// codeqlInput declares an optional runner override for the CodeQL job alone.
func codeqlInput() string {
	return "      codeql_runs_on:\n        required: false\n        default: ''\n"
}

func TestCheckRunsOnForwarding(t *testing.T) {
	t.Parallel()

	t.Run("should accept a forward when only its spacing differs", func(t *testing.T) {
		t.Parallel()
		// given
		directory := workflows(t, withFiles(claudeWorkflows(), map[string]string{
			"go.yaml": runsOnInputs(codeqlInput()) + "jobs:\n  codeql:\n" +
				"    runs-on: ${{ fromJSON(inputs.codeql_runs_on || inputs.runs_on) }}\n",
			"go-docker.yaml": runsOnInputs(codeqlInput()) + "jobs:\n  go:\n" +
				"    uses: './.github/workflows/go.yaml'\n    with:\n      runs_on: ${{inputs.runs_on}}\n" +
				"      codeql_runs_on: \"${{   inputs.codeql_runs_on}}\"\n",
		}))

		// when
		found := findings(t, checkRunsOn, directory)

		// then
		assert.Empty(t, found)
	})

	t.Run("should report every input a call drops when the callee takes them", func(t *testing.T) {
		t.Parallel()
		// given
		directory := workflows(t, withFiles(claudeWorkflows(), map[string]string{
			"go.yaml": runsOnInputs(codeqlInput()) + "jobs:\n  codeql:\n" +
				"    runs-on: ${{ fromJSON(inputs.codeql_runs_on || inputs.runs_on) }}\n",
			"go-docker.yaml": runsOnInputs("") + "jobs:\n  go:\n" +
				"    uses: 'rios0rios0/pipelines/.github/workflows/go.yaml@main'\n" +
				"    with:\n      runs_on: ${{ inputs.other }}\n",
		}))

		// when
		found := findings(t, checkRunsOn, directory)

		// then
		assert.Equal(t, []string{
			"go-docker.yaml: job go calls a workflow without forwarding runs_on; job go calls a workflow that " +
				"takes codeql_runs_on, which this workflow does not declare to forward",
		}, found)
	})

	t.Run("should assume a callee it cannot resolve takes runs_on when the call is external", func(t *testing.T) {
		t.Parallel()
		// given
		directory := workflows(t, withFiles(claudeWorkflows(), map[string]string{
			"go-docker.yaml": runsOnInputs("") + "jobs:\n  go:\n" +
				"    uses: 'someorg/theirrepo/.github/workflows/go.yaml@v1'\n",
		}))

		// when
		found := findings(t, checkRunsOn, directory)

		// then
		assert.Equal(t, []string{"go-docker.yaml: job go calls a workflow without forwarding runs_on"}, found)
	})
}

func TestCheckRunsOnFallbacks(t *testing.T) {
	t.Parallel()

	t.Run("should report every dead link when a fallback chain cannot reach it", func(t *testing.T) {
		t.Parallel()
		// given
		directory := workflows(t, withFiles(claudeWorkflows(), map[string]string{
			"go.yaml": runsOnInputs(codeqlInput()+"      heavy_runs_on:\n        required: true\n") + "jobs:\n" +
				"  past:\n    runs-on: ${{ fromJSON(inputs.runs_on || inputs.codeql_runs_on) }}\n" +
				"  required:\n    runs-on: ${{ fromJSON(inputs.heavy_runs_on || inputs.runs_on) }}\n",
		}))

		// when
		found := findings(t, checkRunsOn, directory)

		// then
		assert.Equal(t, []string{
			"go.yaml: job past falls back past runs_on, which always has a value, so codeql_runs_on is never read; " +
				"job required falls back from inputs.heavy_runs_on, which is not optional with an empty default, so " +
				"the rest of its chain is never reached",
		}, found)
	})

	t.Run("should report an override no job reads when one is declared", func(t *testing.T) {
		t.Parallel()
		// given
		directory := workflows(t, withFiles(claudeWorkflows(), map[string]string{
			"go.yaml": runsOnInputs(codeqlInput()) + "jobs:\n  lint:\n    runs-on: ${{ fromJSON(inputs.runs_on) }}\n",
		}))

		// when
		found := findings(t, checkRunsOn, directory)

		// then
		assert.Equal(t, []string{"go.yaml: declares codeql_runs_on that no job resolves from or forwards"}, found)
	})

	t.Run("should report the input declaration when runs_on is not a mapping", func(t *testing.T) {
		t.Parallel()
		// given
		directory := workflows(t, withFiles(claudeWorkflows(), map[string]string{
			"go.yaml": "on:\n  workflow_call:\n    inputs:\n      runs_on: \"it's\"\njobs: {}\n",
		}))

		// when
		found := findings(t, checkRunsOn, directory)

		// then
		// The finding that no job reads runs_on is added only when nothing else was found.
		assert.Equal(t, []string{`go.yaml: runs_on is not an input declaration ("it's")`}, found)
	})
}
