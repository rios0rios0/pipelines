package reports_test

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/rios0rios0/pipelines/global/scripts/languages/terraform/order-check/internal/domain/entities"
	"github.com/rios0rios0/pipelines/global/scripts/languages/terraform/order-check/internal/infrastructure/reports"
)

func TestRender(t *testing.T) {
	t.Parallel()

	t.Run("should fail a file with an error and carry a warning as the case's output", func(t *testing.T) {
		t.Parallel()
		// given
		results := []entities.FileResult{
			{Path: "a&b.hcl", Findings: []entities.Finding{
				{Rule: "x", Message: "m <1>", Severity: entities.SeverityError},
				{Rule: "y", Message: "n", Severity: entities.SeverityError},
			}},
			{
				Path:     "v.tf",
				Findings: []entities.Finding{{Rule: "w", Message: "warn", Severity: entities.SeverityWarning}},
			},
			{Path: "fixed.tf", Fixed: true},
		}

		// when
		report := reports.Render(results)

		// then
		assert.Equal(t, `<?xml version="1.0" encoding="UTF-8"?>
<testsuites name="order-check" tests="3" failures="1">
  <testsuite name="order-check" tests="3" failures="1">
    <testcase classname="order-check" name="a&amp;b.hcl"><failure message="[x] m &lt;1&gt;; [y] n"/></testcase>
    <testcase classname="order-check" name="v.tf"><system-out>[w] warn</system-out></testcase>
    <testcase classname="order-check" name="fixed.tf"></testcase>
  </testsuite>
</testsuites>
`, report)
	})
}

func TestWrite(t *testing.T) {
	t.Parallel()

	t.Run("should create the report directory inside the repository", func(t *testing.T) {
		t.Parallel()
		// given
		repository, err := filepath.EvalSymlinks(t.TempDir())
		require.NoError(t, err)

		// when
		err = reports.Write(nil, filepath.Join(repository, "build", "reports"), repository)

		// then
		require.NoError(t, err)
		assert.FileExists(t, filepath.Join(repository, "build", "reports", reports.FileName))
	})

	t.Run("should refuse a directory that resolves outside the repository", func(t *testing.T) {
		t.Parallel()
		// given
		parent, err := filepath.EvalSymlinks(t.TempDir())
		require.NoError(t, err)
		repository := filepath.Join(parent, "repo")
		require.NoError(t, os.Mkdir(repository, 0o750))

		// when
		err = reports.Write(nil, repository+"/../escape", repository)

		// then
		var outside *reports.OutsideError
		require.ErrorAs(t, err, &outside)
		assert.Equal(t, "refusing to use '"+repository+"/../escape' as the report directory: it resolves outside "+
			"the repository '"+repository+"'", outside.Message)
		assert.NoDirExists(t, filepath.Join(parent, "escape"))
	})

	t.Run("should refuse a report file that is a symlink out of the directory", func(t *testing.T) {
		t.Parallel()
		// given
		repository, err := filepath.EvalSymlinks(t.TempDir())
		require.NoError(t, err)
		directory := filepath.Join(repository, "reports")
		require.NoError(t, os.Mkdir(directory, 0o750))
		require.NoError(
			t,
			os.Symlink(filepath.Join(repository, "elsewhere.xml"), filepath.Join(directory, reports.FileName)),
		)

		// when
		err = reports.Write(nil, directory, repository)

		// then
		var outside *reports.OutsideError
		require.ErrorAs(t, err, &outside)
	})
}
