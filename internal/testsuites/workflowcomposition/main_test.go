package main

import (
	"bytes"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
)

func TestRun(t *testing.T) {
	t.Parallel()

	t.Run("should print the usage and exit 2 when no check is named", func(t *testing.T) {
		t.Parallel()
		// given
		var stdout, stderr bytes.Buffer

		// when
		status := run(nil, &stdout, &stderr)

		// then
		assert.Equal(t, exitUsage, status)
		assert.Contains(t, stderr.String(), "usage: workflowcomposition <advisory-job|advisory-twin|")
		assert.Empty(t, stdout.String())
	})

	t.Run("should exit 2 when the check named does not exist", func(t *testing.T) {
		t.Parallel()
		// given
		var stdout, stderr bytes.Buffer

		// when
		status := run([]string{"no-such-check", t.TempDir()}, &stdout, &stderr)

		// then
		assert.Equal(t, exitUsage, status)
	})

	t.Run("should print the findings and exit 0 when a check finds a violation", func(t *testing.T) {
		t.Parallel()
		// given
		directory := workflows(t, map[string]string{"ci.yaml": "on: push\njobs: {}\n"})
		var stdout, stderr bytes.Buffer

		// when
		status := run([]string{"runs-on", directory}, &stdout, &stderr)

		// then
		assert.Equal(t, 0, status)
		assert.Equal(t, "no reusable-claude-*.yaml in .github/workflows/ -- renamed, or removed\n", stdout.String())
		assert.Empty(t, stderr.String())
	})

	t.Run("should exit 1 and say why when the fact table cannot list the directory", func(t *testing.T) {
		t.Parallel()
		// given
		missing := filepath.Join(t.TempDir(), "missing")
		var stdout, stderr bytes.Buffer

		// when
		status := run([]string{"facts", missing}, &stdout, &stderr)

		// then
		assert.Equal(t, exitFailed, status)
		assert.Contains(t, stderr.String(), "workflowcomposition facts: open "+missing)
	})
}
