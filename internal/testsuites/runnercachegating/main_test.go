package main

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// tree writes `files` (relative path -> content) under a new directory.
func tree(t *testing.T, files map[string]string) string {
	t.Helper()
	root := t.TempDir()
	for name, content := range files {
		path := filepath.Join(root, filepath.FromSlash(name))
		require.NoError(t, os.MkdirAll(filepath.Dir(path), 0o750))
		require.NoError(t, os.WriteFile(path, []byte(content), 0o600))
	}
	return root
}

func scanned(t *testing.T, root string) []string {
	t.Helper()
	findings, err := scan(root)
	require.NoError(t, err)
	return findings
}

const correctShapes = `runs:
  using: 'composite'
  steps:
    - name: 'Setup Go'
      uses: 'actions/setup-go@x'
      with:
        go-version-file: 'go.mod'
        cache: ${{ runner.environment != 'self-hosted' }}

    - uses: 'actions/setup-go@x'
      with:
        cache: false

    - name: 'Cache the SDK'
      if: "runner.environment != 'self-hosted'"
      uses: 'actions/cache@x'
      with:
        path: |
          ~/.local/share/flutter
        key: 'sdk'

    - uses: 'actions/cache/restore@x'
      with:
        path: '.owasp'

    - uses: 'actions/setup-node@x'
      with:
        cache: 'yarn'
`

func TestScan(t *testing.T) {
	t.Parallel()

	t.Run("should report nothing when every cache is gated, off, in the workspace or setup-node's", func(t *testing.T) {
		t.Parallel()
		// given
		root := tree(t, map[string]string{"ok/action.yaml": correctShapes})

		// when
		findings := scanned(t, root)

		// then
		assert.Empty(t, findings)
	})

	t.Run("should report actions/setup-go when it leaves cache at its default or sets it ungated", func(t *testing.T) {
		t.Parallel()
		// given
		root := tree(t, map[string]string{"action.yaml": "steps:\n  - uses: 'actions/setup-go@x'\n" +
			"    with:\n      go-version-file: 'go.mod'\n  - uses: 'actions/setup-go@x'\n    with:\n      cache: true\n" +
			"  - uses: 'actions/setup-go@x'\n    with:\n      cache:\n"})

		// when
		findings := scanned(t, root)

		// then
		assert.Equal(t, []string{
			"action.yaml:2: actions/setup-go leaves `cache` at its default (on), so a self-hosted runner downloads " +
				"GOMODCACHE over itself and discards it. Set `cache: ${{ runner.environment != 'self-hosted' }}`.",
			"action.yaml:5: actions/setup-go has `cache: true`, which is neither `false` nor gated on " +
				"`runner.environment != 'self-hosted'`.",
			"action.yaml:8: actions/setup-go has `cache: `, which is neither `false` nor gated on " +
				"`runner.environment != 'self-hosted'`.",
		}, findings)
	})

	t.Run("should report an actions/cache naming a $HOME path when it is not gated", func(t *testing.T) {
		t.Parallel()
		// given
		root := tree(t, map[string]string{"action.yml": "steps:\n  - uses: 'actions/cache@x'\n    with:\n" +
			"      # a comment inside the block\n      path: |\n        build/\n        - ${HOME}/.gradle\n" +
			"  - uses: 'actions/cache/save@x'\n    with:\n      path: \"$HOME/.cache\"\n" +
			"  - uses: 'actions/cache@x'\n    with: {path: ~/.npm}\n"})

		// when
		findings := scanned(t, root)

		// then
		assert.Equal(t, []string{
			"action.yml:2: actions/cache names a $HOME path but is not gated -- add " +
				"`if: \"runner.environment != 'self-hosted'\"`.",
			"action.yml:8: actions/cache names a $HOME path but is not gated -- add " +
				"`if: \"runner.environment != 'self-hosted'\"`.",
		}, findings)
	})

	t.Run("should report the inverted gate when it is written in either quote style", func(t *testing.T) {
		t.Parallel()
		// given
		root := tree(t, map[string]string{"action.yaml": "steps:\n  - uses: 'actions/setup-go@x'\n    with:\n" +
			"      cache: ${{ runner.environment == 'github-hosted' }}\n" +
			"  - if: '${{ runner.environment == \"github-hosted\" }}'\n    uses: 'actions/cache@x'\n" +
			"    with:\n      path: '.owasp'\n"})

		// when
		findings := scanned(t, root)

		// then
		assert.Equal(t, []string{
			"action.yaml:2: actions/setup-go has `cache: ${{ runner.environment == 'github-hosted' }}`, which is " +
				"neither `false` nor gated on `runner.environment != 'self-hosted'`.",
			"action.yaml:2: gated on `== 'github-hosted'` (cache), which disables the cache for every consumer " +
				"whose runner reports neither value. Write `!= 'self-hosted'`.",
			"action.yaml:5: gated on `== 'github-hosted'` (if), which disables the cache for every consumer " +
				"whose runner reports neither value. Write `!= 'self-hosted'`.",
		}, findings)
	})

	t.Run("should read linked files and CRLF files and never enter .git or a linked directory", func(t *testing.T) {
		t.Parallel()
		// given
		ungated := "steps:\r\n  - uses: 'actions/setup-go@x'\r\n"
		root := tree(t, map[string]string{
			"real/action.yaml":  ungated,
			".git/action.yaml":  ungated,
			"real/notes.txt":    ungated,
			"other/action.yaml": correctShapes,
		})
		require.NoError(t, os.Symlink(filepath.Join(root, "real", "action.yaml"), filepath.Join(root, "linked.yaml")))
		require.NoError(t, os.Symlink(filepath.Join(root, "real"), filepath.Join(root, "linked-dir")))

		// when
		findings := scanned(t, root)

		// then
		require.Len(t, findings, 2)
		assert.Contains(t, findings[0], "linked.yaml:2: actions/setup-go leaves `cache` at its default")
		assert.Contains(t, findings[1], filepath.Join("real", "action.yaml")+":2: actions/setup-go leaves")
	})
}

func TestRun(t *testing.T) {
	t.Parallel()

	t.Run("should print the findings and exit 0 when the directory is scanned", func(t *testing.T) {
		t.Parallel()
		// given
		root := tree(t, map[string]string{"action.yaml": "steps:\n  - uses: 'actions/setup-go@x'\n"})
		var stdout, stderr bytes.Buffer

		// when
		status := run([]string{root}, &stdout, &stderr)

		// then
		assert.Equal(t, 0, status)
		assert.Contains(t, stdout.String(), "action.yaml:2: actions/setup-go leaves `cache` at its default")
	})

	t.Run("should exit 1 when the directory does not exist", func(t *testing.T) {
		t.Parallel()
		// given
		var stdout, stderr bytes.Buffer

		// when
		status := run([]string{filepath.Join(t.TempDir(), "missing")}, &stdout, &stderr)

		// then
		assert.Equal(t, exitFailed, status)
		assert.Contains(t, stderr.String(), "runnercachegating: ")
	})

	t.Run("should print the usage and exit 2 when no directory is given", func(t *testing.T) {
		t.Parallel()
		// given
		var stdout, stderr bytes.Buffer

		// when
		status := run(nil, &stdout, &stderr)

		// then
		assert.Equal(t, exitUsage, status)
	})
}
