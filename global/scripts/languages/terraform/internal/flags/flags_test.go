package flags_test

import (
	"bytes"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/rios0rios0/pipelines/global/scripts/languages/terraform/internal/flags"
)

func parser() flags.Parser {
	return flags.Parser{Prog: "order-check", Description: "Check file ordering.", Options: []flags.Option{
		{Name: "--fix", Help: "rewrite files"},
		{Name: "--repo-dir", Value: true, Default: ".", Help: "repository root"},
		{Name: "--report", Value: true, Default: "build/reports"},
	}}
}

func TestParse(t *testing.T) {
	t.Parallel()

	t.Run("should read values, switches and unambiguous abbreviations when parsing", func(t *testing.T) {
		t.Parallel()
		// given
		arguments := []string{"--fi", "--repo-dir", "-", "--repo-dir=/work", "--repor=out"}
		var stdout, stderr bytes.Buffer

		// when
		values, _, ok := parser().Parse(arguments, &stdout, &stderr)

		// then
		require.True(t, ok)
		assert.True(t, values.Bool("--fix"))
		assert.Equal(t, "/work", values.String("--repo-dir"))
		assert.Equal(t, "out", values.String("--report"))
		assert.Empty(t, stderr.String())
	})

	t.Run("should fill in the defaults when nothing is given", func(t *testing.T) {
		t.Parallel()
		// given
		var stdout, stderr bytes.Buffer

		// when
		values, _, ok := parser().Parse(nil, &stdout, &stderr)

		// then
		require.True(t, ok)
		assert.False(t, values.Bool("--fix"))
		assert.Equal(t, ".", values.String("--repo-dir"))
		assert.Equal(t, "build/reports", values.String("--report"))
	})

	t.Run("should exit 2 naming both options when an abbreviation is ambiguous", func(t *testing.T) {
		t.Parallel()
		// given
		arguments := []string{"--re", "x"}
		var stdout, stderr bytes.Buffer

		// when
		_, code, ok := parser().Parse(arguments, &stdout, &stderr)

		// then
		assert.False(t, ok)
		assert.Equal(t, flags.ExitUsage, code)
		assert.Equal(t, "usage: order-check [-h] [--fix] [--repo-dir REPO_DIR] [--report REPORT]\n"+
			"order-check: error: ambiguous option: --re could match --repo-dir, --report\n", stderr.String())
	})

	t.Run("should exit 2 when a value is missing or a switch is given one", func(t *testing.T) {
		t.Parallel()
		// given
		var missingOut, missingErr, switchOut, switchErr bytes.Buffer

		// when
		_, missingCode, _ := parser().Parse([]string{"--repo-dir", "--fix"}, &missingOut, &missingErr)
		_, switchCode, _ := parser().Parse([]string{"--fix=yes"}, &switchOut, &switchErr)

		// then
		assert.Equal(t, flags.ExitUsage, missingCode)
		assert.Contains(t, missingErr.String(), "error: argument --repo-dir: expected one argument\n")
		assert.Equal(t, flags.ExitUsage, switchCode)
		assert.Contains(t, switchErr.String(), "error: argument --fix: ignored explicit argument 'yes'\n")
	})

	t.Run("should list every argument it does not know when there are some", func(t *testing.T) {
		t.Parallel()
		// given
		arguments := []string{"stray", "-repo-dir", "x", "--", "--fix"}
		var stdout, stderr bytes.Buffer

		// when
		_, code, _ := parser().Parse(arguments, &stdout, &stderr)

		// then
		assert.Equal(t, flags.ExitUsage, code)
		assert.Contains(t, stderr.String(), "error: unrecognized arguments: stray -repo-dir x -- --fix\n")
	})

	t.Run("should print the help and exit 0 when asked for it", func(t *testing.T) {
		t.Parallel()
		// given
		arguments := []string{"--bogus", "-h"}
		var stdout, stderr bytes.Buffer

		// when
		_, code, ok := parser().Parse(arguments, &stdout, &stderr)

		// then
		assert.False(t, ok)
		assert.Zero(t, code)
		assert.Contains(t, stdout.String(), "\nCheck file ordering.\n\noptions:\n")
		assert.Contains(t, stdout.String(), "  --fix                rewrite files\n")
		assert.Empty(t, stderr.String())
	})
}
