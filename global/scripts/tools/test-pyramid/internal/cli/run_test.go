package cli_test

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/rios0rios0/pipelines/global/scripts/tools/test-pyramid/internal/cli"
)

func environment(values map[string]string) func(string) string {
	return func(name string) string { return values[name] }
}

func noDefaultBranch() string { return "" }

func TestTargetArgument(t *testing.T) {
	t.Parallel()

	t.Run("should take one branch name", func(t *testing.T) {
		t.Parallel()
		// given
		arguments := []string{"develop"}

		// when
		target, err := cli.TargetArgument(arguments)

		// then
		require.NoError(t, err)
		assert.Equal(t, "develop", target)
	})

	t.Run("should refuse an option or a second argument", func(t *testing.T) {
		t.Parallel()
		// given
		invalid := [][]string{{"--fix"}, {"main", "develop"}}

		// when
		var errs []error
		for _, arguments := range invalid {
			_, err := cli.TargetArgument(arguments)
			errs = append(errs, err)
		}

		// then
		for _, err := range errs {
			assert.ErrorContains(t, err, "usage: test-pyramid [target-branch]")
		}
	})
}

func TestBlockingOverride(t *testing.T) {
	t.Parallel()

	t.Run("should insist on blocking only for true", func(t *testing.T) {
		t.Parallel()
		// given
		values := []string{"", "false", "true"}

		// when
		var overrides []bool
		for _, value := range values {
			override, err := cli.BlockingOverride(value)
			require.NoError(t, err)
			overrides = append(overrides, override)
		}

		// then
		assert.Equal(t, []bool{false, false, true}, overrides)
	})

	t.Run("should refuse a value that is not true or false rather than read it as advisory", func(t *testing.T) {
		t.Parallel()
		// given
		value := "ture"

		// when
		_, err := cli.BlockingOverride(value)

		// then
		require.EqualError(t, err, `TEST_PYRAMID_BLOCKING must be 'true' or 'false', not "ture"`)
	})
}

func TestResolveTarget(t *testing.T) {
	t.Parallel()

	t.Run("should prefer the argument, then TEST_PYRAMID_TARGET, then the platform's pull request", func(t *testing.T) {
		t.Parallel()
		// given
		getenv := environment(map[string]string{
			"TEST_PYRAMID_TARGET":                 "release",
			"GITHUB_BASE_REF":                     "main",
			"CI_MERGE_REQUEST_TARGET_BRANCH_NAME": "develop",
		})

		// when
		fromArgument := cli.ResolveTarget("hotfix", getenv, noDefaultBranch)
		fromVariable := cli.ResolveTarget("", getenv, noDefaultBranch)

		// then
		assert.Equal(t, "hotfix", fromArgument)
		assert.Equal(t, "release", fromVariable)
	})

	t.Run("should strip the full ref Azure DevOps names", func(t *testing.T) {
		t.Parallel()
		// given
		getenv := environment(map[string]string{"SYSTEM_PULLREQUEST_TARGETBRANCH": "refs/heads/main"})

		// when
		target := cli.ResolveTarget("", getenv, noDefaultBranch)

		// then
		assert.Equal(t, "main", target)
	})

	t.Run("should fall back to the default branch of origin, then to main", func(t *testing.T) {
		t.Parallel()
		// given
		getenv := environment(map[string]string{})

		// when
		fromOrigin := cli.ResolveTarget("", getenv, func() string { return "trunk" })
		fallback := cli.ResolveTarget("", getenv, noDefaultBranch)

		// then
		assert.Equal(t, "trunk", fromOrigin)
		assert.Equal(t, "main", fallback)
	})
}

func TestReportDirectory(t *testing.T) {
	t.Parallel()

	t.Run("should resolve REPORT_PATH against the repository's root, with a default", func(t *testing.T) {
		t.Parallel()
		// given
		root := "/work/repo"

		// when
		relative := cli.ReportDirectory(root, "reports/test-pyramid")
		absolute := cli.ReportDirectory(root, "/tmp/out")
		fallback := cli.ReportDirectory(root, "")

		// then
		assert.Equal(t, "/work/repo/reports/test-pyramid", relative)
		assert.Equal(t, "/tmp/out", absolute)
		assert.Equal(t, "/work/repo/build/reports/test-pyramid", fallback)
	})
}
