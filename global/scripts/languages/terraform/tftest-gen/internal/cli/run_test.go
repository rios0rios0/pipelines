package cli_test

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/rios0rios0/pipelines/global/scripts/languages/terraform/tftest-gen/internal/cli"
	"github.com/rios0rios0/pipelines/global/scripts/languages/terraform/tftest-gen/internal/domain/repositories"
	"github.com/rios0rios0/pipelines/global/scripts/languages/terraform/tftest-gen/internal/test/doubles"
)

// moduleRoot writes a module with one required, validated variable.
func moduleRoot(t *testing.T) string {
	t.Helper()
	root, err := filepath.EvalSymlinks(t.TempDir())
	require.NoError(t, err)
	variables := "variable \"name\" {\n  type = string\n  validation {\n    condition = true\n  }\n}\n"
	require.NoError(t, os.WriteFile(filepath.Join(root, "variables.tf"), []byte(variables), 0o600))
	return root
}

func run(formatter *doubles.StubFormatter, arguments ...string) (int, string, string) {
	var stdout, stderr bytes.Buffer
	code := cli.RunWith(arguments, &stdout, &stderr, func(string) repositories.Formatter { return formatter })
	return code, stdout.String(), stderr.String()
}

func TestRun(t *testing.T) {
	t.Parallel()

	t.Run("should write the test, report what it found and format it", func(t *testing.T) {
		t.Parallel()
		// given
		root := moduleRoot(t)
		formatter := &doubles.StubFormatter{}

		// when
		code, stdout, stderr := run(formatter, "--repo-dir", root)

		// then
		assert.Zero(t, code)
		assert.Equal(t, "wrote "+root+"/tests/smoke.tftest.hcl (providers=0, vars=1, validations=1)\n", stdout)
		assert.Empty(t, stderr)
		assert.Equal(t, 1, formatter.Calls)
		assert.FileExists(t, filepath.Join(root, "tests", "smoke.tftest.hcl"))
	})

	t.Run("should warn and still succeed when the formatter cannot run", func(t *testing.T) {
		t.Parallel()
		// given
		root := moduleRoot(t)
		warning := "terraform not on PATH; skipping `terraform fmt` on generated file"
		formatter := &doubles.StubFormatter{Warning: warning}

		// when
		code, _, stderr := run(formatter, "--repo-dir", root)

		// then
		assert.Zero(t, code)
		assert.Equal(t, "warning: terraform not on PATH; skipping `terraform fmt` on generated file\n", stderr)
	})

	t.Run("should skip a hand-written test, naming it, without formatting anything", func(t *testing.T) {
		t.Parallel()
		// given
		root := moduleRoot(t)
		require.NoError(t, os.Mkdir(filepath.Join(root, "tests"), 0o750))
		smoke := filepath.Join(root, "tests", "smoke.tftest.hcl")
		require.NoError(t, os.WriteFile(smoke, []byte("# Hand-written\n"), 0o600))
		formatter := &doubles.StubFormatter{}

		// when
		code, stdout, _ := run(formatter, "--repo-dir", root)

		// then
		assert.Zero(t, code)
		assert.Equal(t, "SKIP hand-written smoke at "+smoke+" (use --force to overwrite)\n", stdout)
		assert.Zero(t, formatter.Calls)
	})

	t.Run("should fail when the module directory does not exist", func(t *testing.T) {
		t.Parallel()
		// given
		missing := filepath.Join(t.TempDir(), "missing")

		// when
		code, _, stderr := run(&doubles.StubFormatter{}, "--repo-dir", missing)

		// then
		assert.Equal(t, 1, code)
		assert.Contains(t, stderr, "ERROR: ")
	})
}
