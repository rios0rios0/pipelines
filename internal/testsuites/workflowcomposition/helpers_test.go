package main

import (
	"bytes"
	"maps"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/stretchr/testify/require"
)

// tree writes the files of a fixture repository under a fresh directory and returns it.
func tree(t *testing.T, files map[string]string) string {
	t.Helper()
	root := t.TempDir()
	for name, content := range files {
		path := filepath.Join(root, name)
		require.NoError(t, os.MkdirAll(filepath.Dir(path), 0o750))
		require.NoError(t, os.WriteFile(path, []byte(content), 0o600))
	}
	return root
}

// workflows writes the given workflow files and returns the directory holding them.
func workflows(t *testing.T, files map[string]string) string {
	t.Helper()
	named := make(map[string]string, len(files))
	for name, content := range files {
		named[".github/workflows/"+name] = content
	}
	return filepath.Join(tree(t, named), ".github", "workflows")
}

// findings runs one check over `directory` and returns the lines it printed.
func findings(t *testing.T, run check, directory string) []string {
	t.Helper()
	var buffer bytes.Buffer
	out := &printer{out: &buffer}
	require.NoError(t, run(directory, out))
	require.NoError(t, out.err)
	var lines []string
	for line := range strings.SplitSeq(buffer.String(), "\n") {
		if line != "" {
			lines = append(lines, line)
		}
	}
	return lines
}

// parsed is a document the test knows to be valid.
func parsed(t *testing.T, text string) *value {
	t.Helper()
	document, err := parseDocument([]byte(text), standardYAML)
	require.NoError(t, err)
	return document
}

// claudeWorkflows is a pair of Claude reusables that satisfy every check, so a test can change one
// property and see only the finding that property causes.
func claudeWorkflows() map[string]string {
	runsOn := "on:\n  workflow_call:\n    inputs:\n      runs_on:\n        type: string\n        required: false\n" +
		"        default: '[\"ubuntu-latest\"]'\n"
	return map[string]string{
		"reusable-claude-review.yaml": runsOn + `jobs:
  claude-review:
    if: >-
      github.event.pull_request.head.repo.full_name == github.repository
      && !startsWith(github.event.pull_request.head.ref, 'bump/')
    runs-on: ${{ fromJSON(inputs.runs_on) }}
`,
		"reusable-claude-mention.yaml": runsOn + `jobs:
  claude:
    if: |
      (github.event.comment != null &&
        contains(fromJSON('["OWNER","MEMBER","COLLABORATOR"]'), github.event.comment.author_association))
    runs-on: ${{ fromJSON(inputs.runs_on) }}
`,
	}
}

// withFiles is `base` with `extra` written over it.
func withFiles(base, extra map[string]string) map[string]string {
	merged := maps.Clone(base)
	maps.Copy(merged, extra)
	return merged
}
