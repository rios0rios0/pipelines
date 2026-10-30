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

// verifiedUpload is a composite whose mandatory report is verified, then uploaded at best.
const verifiedUpload = `runs:
  using: composite
  steps:
    - name: 'Verify Report'
      env: {REPORT_DIR: 'build/reports/tool'}
      run: test -d "$REPORT_DIR"
    - name: 'Upload Report'
      uses: 'actions/upload-artifact@x'
      continue-on-error: true
      with: {path: 'build/reports/tool/'}
`

// repository lays out every mandatory stage verified, the deliverable fatal,
// and an empty workflows directory, then `files` over them.
func repository(t *testing.T, files map[string]string) string {
	t.Helper()
	root := t.TempDir()
	all := map[string]string{
		"github/dart/stages/40-delivery/build/action.yaml": "runs:\n  using: composite\n  steps:\n" +
			"    - uses: 'actions/upload-artifact@x'\n      with: {path: build/app}\n",
		".github/workflows/README.md": "not a workflow\n",
	}
	for stage := range mandatory() {
		all[stage] = verifiedUpload
	}
	maps.Copy(all, files)
	for name, content := range all {
		path := filepath.Join(root, filepath.FromSlash(name))
		require.NoError(t, os.MkdirAll(filepath.Dir(path), 0o750))
		require.NoError(t, os.WriteFile(path, []byte(content), 0o600))
	}
	return root
}

// findings checks root and returns its lines for one kind.
func findings(t *testing.T, root, kind string) []string {
	t.Helper()
	var output bytes.Buffer
	require.NoError(t, check(root, &output))
	var selected []string
	for line := range strings.SplitSeq(strings.TrimSuffix(output.String(), "\n"), "\n") {
		if name, finding, ok := strings.Cut(line, "\t"); ok && name == kind {
			selected = append(selected, finding)
		}
	}
	return selected
}

func TestCheck(t *testing.T) {
	t.Parallel()

	t.Run("should report nothing when every report upload is optional and every mandatory one verified",
		func(t *testing.T) {
			t.Parallel()
			// given
			root := repository(t, nil)

			// when
			var output bytes.Buffer
			err := check(root, &output)

			// then
			require.NoError(t, err)
			assert.Empty(t, output.String())
		})

	t.Run("should report an upload that can fail its job when a workflow step is not continue-on-error",
		func(t *testing.T) {
			t.Parallel()
			// given
			root := repository(t, map[string]string{
				".github/workflows/go.yaml": "jobs:\n  lint:\n    steps:\n      - uses: 'actions/upload-artifact@x'\n" +
					"        continue-on-error: 'true'\n      - uses: 'actions/upload-artifact@x'\n        name: ~\n",
				"github/.hidden/action.yaml": "runs:\n  using: composite\n  steps:\n    - uses: 'actions/upload-artifact@x'\n",
			})

			// when
			optional := findings(t, root, "optional")

			// then
			assert.Equal(t, []string{
				".github/workflows/go.yaml :: job lint :: step 0 (unnamed) is not continue-on-error",
				".github/workflows/go.yaml :: job lint :: step 1 (None) is not continue-on-error",
			}, optional)
		})

	t.Run(
		"should report a rule that fails nothing when an optional upload keeps if-no-files-found",
		func(t *testing.T) {
			t.Parallel()
			// given
			root := repository(t, map[string]string{
				"github/go/action.yaml": "runs:\n  using: composite\n  steps:\n    - uses: 'actions/upload-artifact@x'\n" +
					"      continue-on-error: true\n      with: {if-no-files-found: error}\n",
			})

			// when
			silent := findings(t, root, "silent")

			// then
			assert.Equal(t, []string{
				"github/go/action.yaml :: step 0 (unnamed) says `if-no-files-found: error` under continue-on-error, " +
					"which fails nothing",
			}, silent)
		},
	)

	t.Run("should report the verification when it is conditional, checks elsewhere, missing or unlisted",
		func(t *testing.T) {
			t.Parallel()
			// given
			root := repository(t, map[string]string{
				"github/global/stages/20-security/gitleaks/action.yaml": strings.Replace(
					verifiedUpload, "'Verify Report'", "'Check Report'", 1),
				"github/global/stages/20-security/semgrep/action.yaml": strings.Replace(verifiedUpload,
					"env: {REPORT_DIR: 'build/reports/tool'}", "if: always()\n      env: {REPORT_DIR: 'out'}", 1),
				"github/extra/action.yaml": verifiedUpload,
			})

			// when
			verify := findings(t, root, "verify")

			// then
			assert.Equal(t, []string{
				"github/global/stages/20-security/semgrep/action.yaml :: step 1 (Upload Report): `Verify Report` must " +
					"run on the default success() condition",
				"github/global/stages/20-security/semgrep/action.yaml :: step 1 (Upload Report): `Verify Report` " +
					"checks 'out', the upload publishes 'build/reports/tool'",
				"github/global/stages/20-security/gitleaks/action.yaml has no `Verify Report` step right before its upload",
				"github/extra/action.yaml has a `Verify Report` step but is missing from MANDATORY in this test",
			}, verify)
		})

	t.Run("should report a deliverable when its upload is continue-on-error", func(t *testing.T) {
		t.Parallel()
		// given
		root := repository(t, map[string]string{
			"github/dart/stages/40-delivery/build/action.yaml": "runs:\n  using: composite\n  steps:\n" +
				"    - name: 'Upload'\n      uses: 'actions/upload-artifact@x'\n      continue-on-error: true\n",
		})

		// when
		deliverable := findings(t, root, "deliverable")

		// then
		assert.Equal(t, []string{
			"github/dart/stages/40-delivery/build/action.yaml :: step 0 (Upload) uploads the job's product but is " +
				"continue-on-error",
		}, deliverable)
	})

	t.Run("should report a retention the repository does not bound when an upload asks for a bare or uneven number",
		func(t *testing.T) {
			t.Parallel()
			// given
			root := repository(t, map[string]string{
				".github/workflows/go.yaml": "jobs:\n  test:\n    steps:\n" +
					"      - name: 'Coverage'\n        uses: 'actions/upload-artifact@x'\n        continue-on-error: true\n" +
					"        with: {retention-days: 30}\n",
				"github/dart/stages/40-delivery/build/action.yaml": "runs:\n  using: composite\n  steps:\n" +
					"    - uses: 'actions/upload-artifact@x'\n" +
					"      with: {retention-days: '${{ github.retention_days < 30 && github.retention_days || 10 }}'}\n",
			})

			// when
			retention := findings(t, root, "retention")

			// then
			assert.Equal(t, []string{
				".github/workflows/go.yaml :: job test :: step 0 (Coverage) asks for retention-days '30', " +
					"unbounded by the repository's retention",
				"github/dart/stages/40-delivery/build/action.yaml :: step 0 (unnamed) asks for retention-days " +
					"'${{ github.retention_days < 30 && github.retention_days || 10 }}', unbounded by the " +
					"repository's retention",
			}, retention)
		})

	t.Run("should report no retention when an upload bounds its days by the repository's or leaves them out",
		func(t *testing.T) {
			t.Parallel()
			// given
			root := repository(t, map[string]string{
				"github/global/stages/20-security/hadolint/action.yaml": "runs:\n  using: composite\n  steps:\n" +
					"    - uses: 'actions/upload-artifact@x'\n      continue-on-error: true\n" +
					"      with: {retention-days: '${{ github.retention_days < 10 && github.retention_days || 10 }}'}\n" +
					"    - uses: 'actions/upload-artifact@x'\n      continue-on-error: true\n",
			})

			// when
			var output bytes.Buffer
			err := check(root, &output)

			// then
			require.NoError(t, err)
			assert.Empty(t, output.String())
		})

	t.Run("should fail when a file in scope does not parse", func(t *testing.T) {
		t.Parallel()
		// given
		root := repository(t, map[string]string{".github/workflows/broken.yaml": "jobs: [\n"})

		// when
		err := check(root, &bytes.Buffer{})

		// then
		require.ErrorContains(t, err, ".github/workflows/broken.yaml")
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
