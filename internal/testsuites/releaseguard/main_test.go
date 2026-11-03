package main

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// workflows writes `files` (name -> content) into a new directory.
func workflows(t *testing.T, files map[string]string) string {
	t.Helper()
	root := t.TempDir()
	for name, content := range files {
		require.NoError(t, os.WriteFile(filepath.Join(root, name), []byte(content), 0o600))
	}
	return root
}

func TestWiring(t *testing.T) {
	t.Parallel()

	gate := gateConjunct("deployment-release-guard")

	t.Run("should report nothing when every deployment waits for the guard's yes", func(t *testing.T) {
		t.Parallel()
		// given
		root := workflows(t, map[string]string{
			"go-flyio.yaml": guardedWorkflow("!cancelled() && " + gate),
			"go.yaml":       "on: { workflow_call: {} }\njobs:\n  lint: { steps: [ { run: 'true' } ] }\n",
		})

		// when
		findings, err := wiring(root)

		// then
		require.NoError(t, err)
		assert.Empty(t, findings)
	})

	t.Run("should report a deployment whose if: lost the gate", func(t *testing.T) {
		t.Parallel()
		// given
		root := workflows(t, map[string]string{"go-flyio.yaml": guardedWorkflow("!cancelled() && a")})

		// when
		findings, err := wiring(root)

		// then
		require.NoError(t, err)
		require.Len(t, findings, 1)
		assert.Contains(t, findings[0], "go-flyio.yaml: job deployment-flyio deploys when")
	})

	t.Run("should report a directory with no deployment at all, since it checked nothing", func(t *testing.T) {
		t.Parallel()
		// given
		root := workflows(t, map[string]string{"go.yaml": "jobs:\n  lint: { steps: [ { run: 'true' } ] }\n"})

		// when
		findings, err := wiring(root)

		// then
		require.NoError(t, err)
		require.Len(t, findings, 1)
		assert.Contains(t, findings[0], "the scan read nothing")
	})

	t.Run("should report a workflow it cannot read instead of skipping it", func(t *testing.T) {
		t.Parallel()
		// given
		root := workflows(t, map[string]string{
			"broken.yaml":   "jobs: [\n",
			"go-flyio.yaml": guardedWorkflow(gate),
		})

		// when
		findings, err := wiring(root)

		// then
		require.NoError(t, err)
		require.Len(t, findings, 1)
		assert.True(t, strings.HasPrefix(findings[0], "broken.yaml: unreadable"))
	})
}

func TestCanaries(t *testing.T) {
	t.Parallel()

	t.Run("should judge every canary as it must", func(t *testing.T) {
		t.Parallel()
		// given
		// when
		findings := canaryFindings()

		// then
		assert.Empty(t, findings)
	})
}

func TestSplit(t *testing.T) {
	t.Parallel()

	t.Run("should cut at the operator outside parentheses and quotes only", func(t *testing.T) {
		t.Parallel()
		// given
		expression := "a && (b || c) && d == 'x && y' || (e)"

		// when
		clauses := split(expression, "||")
		conjuncts := split(clauses[0], "&&")

		// then
		assert.Equal(t, []string{"a && (b || c) && d == 'x && y'", "e"}, clauses)
		assert.Equal(t, []string{"a", "b || c", "d == 'x && y'"}, conjuncts)
	})

	t.Run("should keep parentheses that do not enclose the whole operand", func(t *testing.T) {
		t.Parallel()
		// given
		expression := "(a) || (b)"

		// when
		operands := split(operand(expression), "&&")

		// then
		assert.Equal(t, []string{"(a) || (b)"}, operands)
	})

	t.Run("should fold the blanks a reformat adds", func(t *testing.T) {
		t.Parallel()
		// given
		expression := "${{\n  (  needs.g.outputs.deploy   ==  'true' )\n}}"

		// when
		operands := split(unwrap(expression), "&&")

		// then
		assert.Equal(t, []string{"needs.g.outputs.deploy == 'true'"}, operands)
	})
}

func TestRun(t *testing.T) {
	t.Parallel()

	t.Run("should refuse arguments that name no command", func(t *testing.T) {
		t.Parallel()
		// given
		var stdout, stderr bytes.Buffer

		// when
		status := run([]string{"wiring"}, &stdout, &stderr)

		// then
		assert.Equal(t, exitUsage, status)
		assert.Contains(t, stderr.String(), usage)
		assert.Empty(t, stdout.String())
	})

	t.Run("should print one finding per line and exit 0 whatever it found", func(t *testing.T) {
		t.Parallel()
		// given
		root := workflows(t, map[string]string{"go-flyio.yaml": guardedWorkflow("!cancelled()")})
		var stdout, stderr bytes.Buffer

		// when
		status := run([]string{"wiring", root}, &stdout, &stderr)

		// then
		assert.Equal(t, 0, status)
		assert.Equal(t, 1, strings.Count(stdout.String(), "\n"))
		assert.Empty(t, stderr.String())
	})
}
