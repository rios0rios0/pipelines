package cli_test

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/rios0rios0/pipelines/global/scripts/languages/terraform/var-catalog/internal/cli"
)

const catalog = "locals {\n  declarations = {\n    environment = <<-EOT\n      variable \"environment\" {\n" +
	"        type = string\n      }\n    EOT\n  }\n}\n"

// repository writes a checkout with the catalog and one stack using it.
func repository(t *testing.T) string {
	t.Helper()
	root, err := filepath.EvalSymlinks(t.TempDir())
	require.NoError(t, err)
	require.NoError(t, os.WriteFile(filepath.Join(root, ".terraform-var-catalog.hcl"), []byte(catalog), 0o600))
	stack := filepath.Join(root, "stacks", "01_alpha")
	require.NoError(t, os.MkdirAll(stack, 0o750))
	require.NoError(t, os.WriteFile(filepath.Join(stack, "main.tf"), []byte("x = var.environment\n"), 0o600))
	return root
}

func run(arguments ...string) (int, string, string) {
	var stdout, stderr bytes.Buffer
	code := cli.Run(arguments, &stdout, &stderr)
	return code, stdout.String(), stderr.String()
}

func TestRun(t *testing.T) {
	t.Parallel()

	t.Run("should write the generated file and say how many when run plainly", func(t *testing.T) {
		t.Parallel()
		// given
		root := repository(t)

		// when
		code, stdout, stderr := run("--repo-dir", root)

		// then
		assert.Zero(t, code)
		assert.Equal(t, "var-catalog: wrote 1 file(s)\n", stdout)
		assert.Empty(t, stderr)
		assert.FileExists(t, filepath.Join(root, "stacks", "01_alpha", "variables-shared.tf"))
	})

	t.Run("should fail naming the stale file and write nothing when checking", func(t *testing.T) {
		t.Parallel()
		// given
		root := repository(t)

		// when
		code, stdout, stderr := run("--repo-dir", root, "--check")

		// then
		assert.Equal(t, 1, code)
		assert.Empty(t, stdout)
		assert.Equal(t, "var-catalog: generated files are out of date:\n  stacks/01_alpha/variables-shared.tf\n"+
			"re-run the var-catalog runner and commit the result\n", stderr)
		assert.NoFileExists(t, filepath.Join(root, "stacks", "01_alpha", "variables-shared.tf"))
	})

	t.Run("should pass once the generated file is committed when checking", func(t *testing.T) {
		t.Parallel()
		// given
		root := repository(t)
		code, _, _ := run("--repo-dir", root)
		require.Zero(t, code)

		// when
		code, stdout, _ := run("--repo-dir", root, "--check")

		// then
		assert.Zero(t, code)
		assert.Equal(t, "var-catalog: generated files are up to date\n", stdout)
	})

	t.Run("should list what would change and exit 0 when reporting", func(t *testing.T) {
		t.Parallel()
		// given
		root := repository(t)

		// when
		code, stdout, _ := run("--repo-dir", root, "--report")

		// then
		assert.Zero(t, code)
		assert.Equal(t, "var-catalog: 1 file(s) would change\n  stacks/01_alpha/variables-shared.tf\n", stdout)
	})

	t.Run("should say there is nothing to do when the repository has no catalog", func(t *testing.T) {
		t.Parallel()
		// given
		root, err := filepath.EvalSymlinks(t.TempDir())
		require.NoError(t, err)

		// when
		code, stdout, _ := run("--repo-dir", root)

		// then
		assert.Zero(t, code)
		assert.Equal(t, "var-catalog: no .terraform-var-catalog.hcl in "+root+"; nothing to do\n", stdout)
	})

	t.Run("should exit 2 when the command line names an unknown option", func(t *testing.T) {
		t.Parallel()
		// given
		arguments := []string{"--bogus"}

		// when
		code, _, stderr := run(arguments...)

		// then
		assert.Equal(t, 2, code)
		assert.Contains(t, stderr, "var-catalog: error: unrecognized arguments: --bogus\n")
	})
}
