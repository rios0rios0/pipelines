package main

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestWriteFacts(t *testing.T) {
	t.Parallel()

	t.Run("should emit one fact per line shape when a workflow has every shape", func(t *testing.T) {
		t.Parallel()
		// given
		directory := workflows(t, map[string]string{
			"go-flyio.yaml": "on:\r\n  workflow_call:\r\njobs:\r\n  # fifth stage\r\n  deployment-flyio:\r\n" +
				"    name: 'deployment > flyio'\r\n    needs: [ build ]\r\n    environment: production\r\n" +
				"    if: github.ref == 'refs/heads/main'\r\n    permissions: {}\r\n" +
				"    uses: 'rios0rios0/pipelines/.github/workflows/x.yaml@main' # pinned\r\n" +
				"      - uses: actions/checkout@abc # v7\r\n",
			"notes.txt": "jobs:\n  ignored:\n",
		})

		// when
		facts := findings(t, writeFacts, directory)

		// then
		assert.Equal(t, []string{
			"reusable\tgo-flyio.yaml\t\t",
			"job\tgo-flyio.yaml\tdeployment-flyio\tfifth",
			"job-name\tgo-flyio.yaml\tdeployment-flyio\tdeployment > flyio",
			"job-has-needs\tgo-flyio.yaml\tdeployment-flyio\t",
			"job-has-environment\tgo-flyio.yaml\tdeployment-flyio\t",
			"job-has-if\tgo-flyio.yaml\tdeployment-flyio\t",
			"job-has-permissions\tgo-flyio.yaml\tdeployment-flyio\t",
			"uses\tgo-flyio.yaml\tdeployment-flyio\trios0rios0/pipelines/.github/workflows/x.yaml@main",
			"uses\tgo-flyio.yaml\tdeployment-flyio\tactions/checkout@abc",
		}, facts)
	})

	t.Run("should report a coupling by name when a workflow runs on another's completion", func(t *testing.T) {
		t.Parallel()
		// given
		directory := workflows(t, map[string]string{
			"deploy.yaml": "on:\n  workflow_run:\n    workflows: [ CI ]\njobs:\n  a:\n",
		})

		// when
		facts := findings(t, writeFacts, directory)

		// then
		assert.Equal(t, []string{"workflow-run\tdeploy.yaml\t\t", "job\tdeploy.yaml\ta\t"}, facts)
	})

	t.Run("should fail when a workflow is not UTF-8 text", func(t *testing.T) {
		t.Parallel()
		// given
		directory := t.TempDir()
		require.NoError(t, os.WriteFile(filepath.Join(directory, "bad.yaml"), []byte{0xff, '\n'}, 0o600))
		var buffer bytes.Buffer

		// when
		err := writeFacts(directory, &printer{out: &buffer})

		// then
		require.ErrorContains(t, err, "bad.yaml is not UTF-8 text")
	})
}
