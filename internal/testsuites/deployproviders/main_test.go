package main

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// workflow writes a workflow named `name` into a new directory and returns its path.
func workflow(t *testing.T, name, content string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), name)
	require.NoError(t, os.WriteFile(path, []byte(content), 0o600))
	return path
}

const deployment = `on:
  workflow_call:
    inputs:
      fly_build_from_source:
        type: 'boolean'
        default: false
jobs:
  deployment:
    steps:
      - uses: 'rios0rios0/pipelines/github/global/stages/50-deployment/require-checks@main'
        with:
          needs: "${{ toJSON(needs) }}"
      - name: 'Mask the build secrets'
        if: "env.BUILD_ENV_SECRETS != ''"
        run: |
          echo masked
`

func TestRequireChecksNeeds(t *testing.T) {
	t.Parallel()

	t.Run("should list what each gate step is handed when workflows run the gate", func(t *testing.T) {
		t.Parallel()
		// given
		first := workflow(t, "go-flyio.yaml", deployment)
		second := workflow(t, "npm-cloudflare.yaml", "jobs:\n  deploy:\n    steps:\n"+
			"      - uses: 'x/50-deployment/require-checks@main'\n      - uses: 'actions/checkout@x'\n")

		// when
		var output bytes.Buffer
		err := requireChecksNeeds([]string{first, second}, &output)

		// then
		require.NoError(t, err)
		assert.Equal(t, "go-flyio.yaml\t${{ toJSON(needs) }}\nnpm-cloudflare.yaml\t\n", output.String())
	})

	t.Run("should fail when a workflow does not parse", func(t *testing.T) {
		t.Parallel()
		// given
		broken := workflow(t, "broken.yaml", "jobs: [\n")

		// when
		err := requireChecksNeeds([]string{broken}, &bytes.Buffer{})

		// then
		require.ErrorContains(t, err, "broken.yaml")
	})
}

func TestSecretsStep(t *testing.T) {
	t.Parallel()

	t.Run("should print the script of the step gated on BUILD_ENV_SECRETS when there is one", func(t *testing.T) {
		t.Parallel()
		// given
		path := workflow(t, "go-flyio.yaml", deployment)

		// when
		var output bytes.Buffer
		err := secretsStep(path, &output)

		// then
		require.NoError(t, err)
		assert.Equal(t, "echo masked\n", output.String())
	})

	t.Run("should say no step was found when none is gated on BUILD_ENV_SECRETS", func(t *testing.T) {
		t.Parallel()
		// given
		path := workflow(t, "go.yaml", "jobs:\n  lint:\n    steps:\n      - run: echo\n")

		// when
		var output bytes.Buffer
		err := secretsStep(path, &output)

		// then
		require.NoError(t, err)
		assert.Equal(t, "no step gated on BUILD_ENV_SECRETS was found\n", output.String())
	})
}

func TestInputOff(t *testing.T) {
	t.Parallel()

	cases := map[string]struct {
		input string
		holds bool
	}{
		"should hold when the input is a boolean that defaults to false": {
			input: "{type: 'boolean', default: false}", holds: true,
		},
		"should hold when the default is a zero, which compares equal to false": {
			input: "{type: 'boolean', default: 0}", holds: true,
		},
		"should fail when the default is true":    {input: "{type: 'boolean', default: true}", holds: false},
		"should fail when the default is null":    {input: "{type: 'boolean', default: ~}", holds: false},
		"should fail when the default is missing": {input: "{type: 'boolean'}", holds: false},
		"should fail when the default is the text 'false'": {
			input: "{type: 'boolean', default: 'false'}", holds: false,
		},
		"should fail when the input is a string": {input: "{type: 'string', default: false}", holds: false},
	}
	for name, scenario := range cases {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			// given
			path := workflow(t, "go-flyio.yaml", "on:\n  workflow_call:\n    inputs:\n      fly_build_from_source: "+
				scenario.input+"\n")

			// when
			err := inputOff(path, "fly_build_from_source")

			// then
			if scenario.holds {
				require.NoError(t, err)
			} else {
				require.ErrorIs(t, err, errFailed)
			}
		})
	}
}

func TestRun(t *testing.T) {
	t.Parallel()

	t.Run("should exit 1 quietly when the input check does not hold", func(t *testing.T) {
		t.Parallel()
		// given
		path := workflow(t, "go-flyio.yaml", "on:\n  workflow_call:\n    inputs: {}\n")
		var stdout, stderr bytes.Buffer

		// when
		status := run([]string{"input-off", path, "fly_build_from_source"}, &stdout, &stderr)

		// then
		assert.Equal(t, exitFailed, status)
		assert.Empty(t, stderr.String())
	})

	t.Run("should print the usage and exit 2 when the command is unknown", func(t *testing.T) {
		t.Parallel()
		// given
		var stdout, stderr bytes.Buffer

		// when
		status := run([]string{"require-checks-needs"}, &stdout, &stderr)

		// then
		assert.Equal(t, exitUsage, status)
		assert.Contains(t, stderr.String(), "usage:")
	})

	t.Run("should say why and exit 1 when a workflow cannot be read", func(t *testing.T) {
		t.Parallel()
		// given
		var stdout, stderr bytes.Buffer
		missing := filepath.Join(t.TempDir(), "missing.yaml")

		// when
		status := run([]string{"secrets-step", missing}, &stdout, &stderr)

		// then
		assert.Equal(t, exitFailed, status)
		assert.Contains(t, stderr.String(), "deployproviders: ")
	})
}
