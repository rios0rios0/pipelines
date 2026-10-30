package cli_test

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/rios0rios0/pipelines/global/scripts/languages/terraform/order-check/internal/cli"
)

// checkout writes a stack whose providers.tf is out of order.
func checkout(t *testing.T) string {
	t.Helper()
	root, err := filepath.EvalSymlinks(t.TempDir())
	require.NoError(t, err)
	stack := filepath.Join(root, "stacks", "app")
	require.NoError(t, os.MkdirAll(stack, 0o750))
	providers := "terraform {\n  required_providers {\n    random = {}\n    azurerm = {}\n  }\n}\n"
	require.NoError(t, os.WriteFile(filepath.Join(stack, "providers.tf"), []byte(providers), 0o600))
	return root
}

func run(arguments ...string) (int, string, string) {
	var stdout, stderr bytes.Buffer
	code := cli.Run(arguments, &stdout, &stderr)
	return code, stdout.String(), stderr.String()
}

func TestRun(t *testing.T) {
	t.Parallel()

	t.Run("should print the error and the verdict on stderr and exit 1 when checking", func(t *testing.T) {
		t.Parallel()
		// given
		root := checkout(t)

		// when
		code, stdout, stderr := run("--repo-dir", root, "--report", "build/reports")

		// then
		assert.Equal(t, 1, code)
		assert.Empty(t, stdout)
		assert.Equal(t, "  ERROR: [providers] stacks/app/providers.tf: required_providers not ordered "+
			"heaviest->lightest: ['random', 'azurerm']\n\norder-check: 1 ordering error(s) across 1 file(s). "+
			"Run with --fix to auto-sort. (0 warning(s).)\n", stderr)
		assert.FileExists(t, filepath.Join(root, "build", "reports", "junit-order-check.xml"))
	})

	t.Run("should rewrite the file and pass when fixing", func(t *testing.T) {
		t.Parallel()
		// given
		root := checkout(t)

		// when
		code, stdout, _ := run("--repo-dir", root, "--report", "build/reports", "--fix")
		recheck, _, _ := run("--repo-dir", root, "--report", "build/reports")

		// then
		assert.Zero(t, code)
		assert.Contains(t, stdout, "  FIXED: stacks/app/providers.tf\n\norder-check: rewrote 1 file(s); "+
			"0 unfixable error(s), 0 warning(s).\n  Tip: run your formatter")
		assert.Zero(t, recheck)
	})

	t.Run("should fail naming the directory when the repository does not exist", func(t *testing.T) {
		t.Parallel()
		// given
		missing := filepath.Join(t.TempDir(), "missing")

		// when
		code, _, stderr := run("--repo-dir", missing)

		// then
		assert.Equal(t, 1, code)
		assert.Contains(t, stderr, "ERROR: repo dir not found: ")
	})

	t.Run("should refuse a report directory outside the repository", func(t *testing.T) {
		t.Parallel()
		// given
		root := checkout(t)

		// when
		code, _, stderr := run("--repo-dir", root, "--report", "../../escape")

		// then
		assert.Equal(t, 1, code)
		assert.Contains(t, stderr, "refusing to use '"+root+"/../../escape' as the report directory")
	})
}
