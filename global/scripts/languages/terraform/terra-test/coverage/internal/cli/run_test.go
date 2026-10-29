package cli_test

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/rios0rios0/pipelines/global/scripts/languages/terraform/terra-test/coverage/internal/cli"
)

// rootLayout writes a module published as its own repository, with a test.
func rootLayout(t *testing.T) string {
	t.Helper()
	root, err := filepath.EvalSymlinks(t.TempDir())
	require.NoError(t, err)
	main := "resource \"aws_s3_bucket\" \"logs\" {}\n\noutput \"id\" {\n  value = aws_s3_bucket.logs.id\n}\n"
	require.NoError(t, os.WriteFile(filepath.Join(root, "main.tf"), []byte(main), 0o600))
	require.NoError(t, os.Mkdir(filepath.Join(root, "tests"), 0o750))
	test := "run \"r\" {\n  assert {\n    condition = output.id != \"\"\n  }\n}\n"
	require.NoError(t, os.WriteFile(filepath.Join(root, "tests", "smoke.tftest.hcl"), []byte(test), 0o600))
	return root
}

func run(arguments ...string) (int, string, string) {
	var stdout, stderr bytes.Buffer
	code := cli.Run(arguments, &stdout, &stderr)
	return code, stdout.String(), stderr.String()
}

func TestRun(t *testing.T) {
	t.Parallel()

	t.Run("should write the report and summarise it, granularity caveat included", func(t *testing.T) {
		t.Parallel()
		// given
		root := rootLayout(t)

		// when
		code, stdout, stderr := run("--repo-dir", root, "--output", "build/reports/cov.xml")

		// then
		assert.Zero(t, code)
		assert.Empty(t, stderr)
		assert.Contains(t, stdout, "terra generic coverage: 2/2 blocks (100%) -> "+root+"/build/reports/cov.xml\n")
		assert.Contains(t, stdout, "granularity is per BLOCK, not per line")
		assert.FileExists(t, filepath.Join(root, "build", "reports", "cov.xml"))
	})

	t.Run("should print nothing when quiet", func(t *testing.T) {
		t.Parallel()
		// given
		root := rootLayout(t)

		// when
		code, stdout, _ := run("--repo-dir", root, "--output", "out.xml", "--quiet")

		// then
		assert.Zero(t, code)
		assert.Empty(t, stdout)
	})

	t.Run("should refuse an output outside the repository and write nothing", func(t *testing.T) {
		t.Parallel()
		// given
		root := rootLayout(t)

		// when
		code, _, stderr := run("--repo-dir", root, "--output", "../escaped.xml")

		// then
		assert.Equal(t, 2, code)
		assert.Contains(t, stderr, "--output must stay inside "+root+", got ")
		assert.NoFileExists(t, filepath.Join(filepath.Dir(root), "escaped.xml"))
	})

	t.Run("should say there is nothing to measure and still exit 0 in an empty tree", func(t *testing.T) {
		t.Parallel()
		// given
		root, err := filepath.EvalSymlinks(t.TempDir())
		require.NoError(t, err)

		// when
		code, stdout, _ := run("--repo-dir", root, "--output", "nested/dir/out.xml")

		// then
		assert.Zero(t, code)
		assert.Contains(t, stdout, "nothing to measure")
		assert.FileExists(t, filepath.Join(root, "nested", "dir", "out.xml"))
	})
}
