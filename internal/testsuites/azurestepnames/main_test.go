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

const scriptsRepoTemplate = "steps:\n  - checkout: pipelines\n    name: 'Scripts'\n"

// repository lays out azure-devops/ with the scripts-repo abstract plus `files`.
func repository(t *testing.T, files map[string]string) string {
	t.Helper()
	root := t.TempDir()
	files["global/abstracts/scripts-repo.yaml"] = scriptsRepoTemplate
	for name, content := range files {
		path := filepath.Join(root, "azure-devops", filepath.FromSlash(name))
		require.NoError(t, os.MkdirAll(filepath.Dir(path), 0o750))
		require.NoError(t, os.WriteFile(path, []byte(content), 0o600))
	}
	return root
}

// findings expands root and returns its lines for one assertion.
func findings(t *testing.T, root, group string) []string {
	t.Helper()
	var output bytes.Buffer
	require.NoError(t, expandAll(root, &output))
	var selected []string
	for line := range strings.SplitSeq(strings.TrimSuffix(output.String(), "\n"), "\n") {
		if name, finding, ok := strings.Cut(line, "\t"); ok && name == group {
			selected = append(selected, finding)
		}
	}
	return selected
}

func TestExpandAll(t *testing.T) {
	t.Parallel()

	t.Run("should report nothing when every job checks the scripts out once", func(t *testing.T) {
		t.Parallel()
		// given
		root := repository(t, map[string]string{
			"golang/stages/go.yaml": "jobs:\n  - job: lint\n    steps:\n" +
				"      - template: '../../global/abstracts/scripts-repo.yaml'\n" +
				"      - script: $(Scripts.Directory)/global/scripts/lint/run.sh\n        name: Lint\n",
		})

		// when
		var output bytes.Buffer
		err := expandAll(root, &output)

		// then
		require.NoError(t, err)
		assert.Empty(t, output.String())
	})

	t.Run("should report a duplicate name when a job includes scripts-repo directly and through an abstract",
		func(t *testing.T) {
			t.Parallel()
			// given
			root := repository(t, map[string]string{
				"golang/abstracts/go.yaml": "steps:\n  - template: '../../global/abstracts/scripts-repo.yaml'\n",
				"golang/stages/go.yaml": "jobs:\n  - ${{ if true }}:\n    - job: sca_govulncheck\n      steps:\n" +
					"        - template: '../abstracts/go.yaml'\n" +
					"        - template: '../../global/abstracts/scripts-repo.yaml'\n",
			})

			// when
			duplicates := findings(t, root, "duplicate")

			// then
			assert.Equal(t, []string{
				"azure-devops/golang/stages/go.yaml: job sca_govulncheck declares the step name 'Scripts' 2 times",
			}, duplicates)
		})

	t.Run("should report a job that uses the scripts directory without checking the scripts out", func(t *testing.T) {
		t.Parallel()
		// given
		root := repository(t, map[string]string{
			"golang/stages/go.yaml": "jobs:\n  - job: test\n    steps:\n" +
				"      - ${{ each tier in parameters.TIERS }}:\n" +
				"        - bash: |\n            # explained: $(Scripts.Directory) is unused here\n            echo\n" +
				"      - script: $(Scripts.Directory)/global/scripts/test/run.sh\n" +
				"  - job: documented\n    steps:\n" +
				"      - script: |\n          # there is no $(Scripts.Directory) to source yet\n          echo\n",
		})

		// when
		missing := findings(t, root, "scripts")

		// then
		assert.Equal(t, []string{
			"azure-devops/golang/stages/go.yaml: job test uses $(Scripts.Directory) but never includes scripts-repo",
		}, missing)
	})

	t.Run("should report a job once when two entry templates reach it", func(t *testing.T) {
		t.Parallel()
		// given
		root := repository(t, map[string]string{
			"shared/jobs.yaml": "jobs:\n  - job: twice\n    steps:\n      - script: a\n        name: S\n" +
				"      - script: b\n        name: S\n",
			"entry-a.yaml": "stages:\n  - stage: a\n    jobs:\n      - template: shared/jobs.yaml\n",
			"entry-b.yaml": "stages:\n  - stage: b\n    jobs:\n      - template: shared/jobs.yaml\n",
		})

		// when
		duplicates := findings(t, root, "duplicate")

		// then
		assert.Equal(t, []string{
			"azure-devops/shared/jobs.yaml: job twice declares the step name 'S' 2 times",
		}, duplicates)
	})

	t.Run("should report an include that points at nothing against the template naming it", func(t *testing.T) {
		t.Parallel()
		// given
		root := repository(t, map[string]string{
			"golang/stages/go.yaml": "jobs:\n  - job: lint\n    steps:\n      - template: ../abstracts/gone.yaml\n" +
				"      - template: steps.yaml@pipelines\n",
		})

		// when
		unreadable := findings(t, root, "unreadable")

		// then
		assert.Equal(t, []string{
			"azure-devops/golang/stages/go.yaml: missing include (azure-devops/golang/abstracts/gone.yaml)",
		}, unreadable)
	})

	t.Run("should report a template that does not parse when one is malformed", func(t *testing.T) {
		t.Parallel()
		// given
		root := repository(t, map[string]string{"broken.yaml": "jobs: [\n"})

		// when
		unreadable := findings(t, root, "unreadable")

		// then
		require.Len(t, unreadable, 1)
		assert.True(t, strings.HasPrefix(unreadable[0], "azure-devops/broken.yaml: unparseable (yaml: line"),
			unreadable[0])
	})

	t.Run("should expand each step once when step templates include each other", func(t *testing.T) {
		t.Parallel()
		// given
		root := repository(t, map[string]string{
			"a.yaml":    "steps:\n  - template: b.yaml\n  - script: x\n    name: A\n",
			"b.yaml":    "steps:\n  - template: a.yaml\n",
			"jobs.yaml": "jobs:\n  - job: loop\n    steps:\n      - template: a.yaml\n",
		})

		// when
		duplicates := findings(t, root, "duplicate")

		// then
		assert.Empty(t, duplicates)
	})

	t.Run("should fail when there is no azure-devops directory", func(t *testing.T) {
		t.Parallel()
		// given
		root := t.TempDir()

		// when
		err := expandAll(root, &bytes.Buffer{})

		// then
		require.ErrorIs(t, err, os.ErrNotExist)
	})
}

func TestRun(t *testing.T) {
	t.Parallel()

	t.Run("should print the usage and exit 2 when it is given an argument", func(t *testing.T) {
		t.Parallel()
		// given
		var stdout, stderr bytes.Buffer

		// when
		status := run([]string{"unexpected"}, &stdout, &stderr)

		// then
		assert.Equal(t, exitUsage, status)
		assert.Contains(t, stderr.String(), "usage:")
	})
}
