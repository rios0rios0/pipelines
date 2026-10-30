package main

import (
	"bytes"
	"maps"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

const actionPath = "github/global/stages/20-security/codeql/action.yaml"

const goodAction = `runs:
  using: composite
  steps:
    - uses: 'github/codeql-action/init@x'
      with: {queries: 'security-and-quality'}
    - id: 'analyze'
      uses: 'github/codeql-action/analyze@x'
      with: {upload: 'never'}
    - name: 'Gate on Findings'
      env: {SARIF_DIRECTORY: "${{ steps.analyze.outputs.sarif-output }}"}
      run: '"$GITHUB_ACTION_PATH/../../../../../global/scripts/tools/codeql/gate.sh" "$SARIF_DIRECTORY"'
    - if: "always() && inputs.upload == 'always'"
      continue-on-error: true
      uses: 'github/codeql-action/upload-sarif@x'
      with: {sarif_file: "${{ steps.analyze.outputs.sarif-output }}"}
`

const goodSuppressions = "# header\n\n# 2026-10-20 -- why this one is safe\nabc123:1\n"

// repository lays out what both checks read, satisfying them, then `files`.
func repository(t *testing.T, files map[string]string) string {
	t.Helper()
	root := t.TempDir()
	all := map[string]string{
		actionPath:                goodAction,
		"codeql-config.yml":       "query-filters:\n  - exclude:\n      id: 'actions/unpinned-tag'\n",
		".codeql-false-positives": goodSuppressions,
		"global/scripts/tools/codeql/.codeql-false-positives": "# lists nothing\n",
	}
	maps.Copy(all, files)
	for name, content := range all {
		path := filepath.Join(root, filepath.FromSlash(name))
		require.NoError(t, os.MkdirAll(filepath.Dir(path), 0o750))
		require.NoError(t, os.WriteFile(path, []byte(content), 0o600))
	}
	gate := filepath.Join(root, filepath.FromSlash(gateScript))
	require.NoError(t, os.WriteFile(gate, []byte("#!/bin/sh\n"), 0o700))
	return root
}

func compositeFindings(t *testing.T, root string) []string {
	t.Helper()
	var output bytes.Buffer
	require.NoError(t, checkComposite(filepath.Join(root, actionPath), root, &output))
	return lines(output.String())
}

func ownScan(t *testing.T, root string) []string {
	t.Helper()
	var output bytes.Buffer
	require.NoError(t, checkOwnScan(root, &output))
	return lines(output.String())
}

func lines(text string) []string {
	if text == "" {
		return nil
	}
	return strings.Split(strings.TrimSuffix(text, "\n"), "\n")
}

func TestCheckComposite(t *testing.T) {
	t.Parallel()

	t.Run("should report nothing when the composite analyses, gates and uploads in that order", func(t *testing.T) {
		t.Parallel()
		// given
		root := repository(t, nil)

		// when
		findings := compositeFindings(t, root)

		// then
		assert.Empty(t, findings)
	})

	t.Run("should report every rule when the composite breaks them all", func(t *testing.T) {
		t.Parallel()
		// given
		root := repository(t, map[string]string{actionPath: `runs:
  using: composite
  steps:
    - uses: 'github/codeql-action/init@x'
      with: {queries: 'security-extended'}
    - name: 'Gate'
      if: always()
      continue-on-error: true
      run: '"$GITHUB_ACTION_PATH/../../../../gate.sh" global/scripts/tools/codeql/gate.sh'
    - uses: 'github/codeql-action/upload-sarif@x'
      continue-on-error: 'true'
      if: success()
      with: {sarif_file: 'results'}
    - id: 'analyse'
      uses: 'github/codeql-action/analyze@x'
    - continue-on-error: 1
`})

		// when
		findings := compositeFindings(t, root)

		// then
		assert.Equal(t, []string{
			"init does not run the security-and-quality suite run.sh runs",
			"the analyze step is not id 'analyze', which the gate and the upload read",
			"analyze uploads, so code scanning being unavailable can fail the analysis step",
			"the gate step carries an if:, so something can skip it",
			"the gate step is continue-on-error, so a finding fails nothing",
			"the gate does not read the analysis output",
			"the gate path resolves to github/gate.sh, not the gate script",
			"the gate runs before the analysis",
			"the upload step is not continue-on-error, so a refused upload fails the job",
			"the upload step does not run after a failed gate",
			"the upload step ignores the upload input",
			"the upload does not publish the analysis output",
			"step 1 (Gate) is continue-on-error; only the upload may be",
			"step 4 (None) is continue-on-error; only the upload may be",
		}, findings)
	})

	t.Run("should report each missing step when the composite has no steps", func(t *testing.T) {
		t.Parallel()
		// given
		root := repository(t, map[string]string{actionPath: "runs:\n  using: composite\n"})

		// when
		findings := compositeFindings(t, root)

		// then
		assert.Equal(t, []string{
			"init does not run the security-and-quality suite run.sh runs",
			"no analyze step",
			"no step runs the gate",
			"no upload-sarif step",
		}, findings)
	})

	t.Run("should report the gate when it is not reached through the action path", func(t *testing.T) {
		t.Parallel()
		// given
		root := repository(t, map[string]string{actionPath: strings.Replace(
			goodAction,
			`"$GITHUB_ACTION_PATH/../../../../../global/scripts/tools/codeql/gate.sh"`,
			"global/scripts/tools/codeql/gate.sh",
			1,
		)})

		// when
		findings := compositeFindings(t, root)

		// then
		assert.Equal(t, []string{"the gate is not reached through the action path"}, findings)
	})

	t.Run("should report the gate script when it is not executable", func(t *testing.T) {
		t.Parallel()
		// given
		root := repository(t, nil)
		require.NoError(t, os.Chmod(filepath.Join(root, filepath.FromSlash(gateScript)), 0o600))

		// when
		findings := compositeFindings(t, root)

		// then
		assert.Equal(t, []string{"the gate script is not executable"}, findings)
	})
}

func TestCheckOwnScan(t *testing.T) {
	t.Parallel()

	t.Run("should report nothing when the scan narrows only what it explains", func(t *testing.T) {
		t.Parallel()
		// given
		root := repository(t, nil)

		// when
		findings := ownScan(t, root)

		// then
		assert.Empty(t, findings)
	})

	t.Run("should report the configuration when it sets or filters more than the one query", func(t *testing.T) {
		t.Parallel()
		// given
		root := repository(t, map[string]string{"codeql-config.yml": "query-filters:\n" +
			"  - exclude: {id: actions/unpinned-tag}\n  - exclude: {id: js/xss}\npaths: [src]\n"})

		// when
		findings := ownScan(t, root)

		// then
		assert.Equal(t, []string{
			"codeql-config.yml sets more than query-filters: ['paths', 'query-filters']",
			"codeql-config.yml filters more than actions/unpinned-tag: [{'exclude': {'id': 'actions/unpinned-tag'}}, " +
				"{'exclude': {'id': 'js/xss'}}]",
		}, findings)
	})

	t.Run("should report an empty configuration as filtering nothing it explains", func(t *testing.T) {
		t.Parallel()
		// given
		root := repository(t, map[string]string{"codeql-config.yml": ""})

		// when
		findings := ownScan(t, root)

		// then
		assert.Equal(t, []string{
			"codeql-config.yml sets more than query-filters: []",
			"codeql-config.yml filters more than actions/unpinned-tag: None",
		}, findings)
	})

	t.Run("should report a suppression when it is undated or not a bare fingerprint", func(t *testing.T) {
		t.Parallel()
		// given
		root := repository(t, map[string]string{
			".codeql-false-positives": "early:1\nabc:1\n# 2026-01-01 -- reason\ncafe:7  # trailing\nok:x\n",
		})

		// when
		findings := ownScan(t, root)

		// then
		assert.Equal(t, []string{
			".codeql-false-positives:1 is not a bare fingerprint, so it silences nothing: 'early:1'",
			".codeql-false-positives:2 has no dated rationale above it",
			".codeql-false-positives:4 is not a bare fingerprint, so it silences nothing: 'cafe:7  # trailing'",
			".codeql-false-positives:5 is not a bare fingerprint, so it silences nothing: 'ok:x'",
		}, findings)
	})

	t.Run("should report the consumers' default when it lists a fingerprint", func(t *testing.T) {
		t.Parallel()
		// given
		root := repository(t, map[string]string{
			"global/scripts/tools/codeql/.codeql-false-positives": "# none\n  0abc:1  \n",
		})

		// when
		findings := ownScan(t, root)

		// then
		assert.Equal(t, []string{"the consumers' default .codeql-false-positives lists line 2: '0abc:1'"}, findings)
	})
}

func TestRun(t *testing.T) {
	t.Parallel()

	t.Run("should print an unreadable file as a finding and exit 1 when a check cannot run", func(t *testing.T) {
		t.Parallel()
		// given
		root := t.TempDir()
		var stdout, stderr bytes.Buffer

		// when
		status := run([]string{"own-scan", root}, &stdout, &stderr)

		// then
		assert.Equal(t, exitFailed, status)
		assert.Contains(t, stdout.String(), "could not run the check: ")
	})

	t.Run("should print the usage and exit 2 when the command is unknown", func(t *testing.T) {
		t.Parallel()
		// given
		var stdout, stderr bytes.Buffer

		// when
		status := run([]string{"composite"}, &stdout, &stderr)

		// then
		assert.Equal(t, exitUsage, status)
		assert.Contains(t, stderr.String(), "usage:")
		assert.Empty(t, stdout.String())
	})
}
