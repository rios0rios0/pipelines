// Package cli is the coverage report's command line: it parses the
// arguments, measures the module tree and writes the report, with a summary
// a CI log reads.
//
// The terra-test tier also writes a Cobertura file, but that one answers
// "which modules have a test file" -- a breadth signal: every block of a
// 40-block module counts as covered because one smoke test exists next to it.
// This report answers the narrower, honest question: which declared blocks
// are reachable from an assertion `terraform test` actually ran?
//
// It reads the HCL rather than `terraform test -json`, and that is settled: a
// passing run reports only which runs passed, never what their assertions
// evaluated, and the plan `-verbose` adds must never count as coverage,
// because every module that compiles appears in it.
//
//   - Denominator: every top-level `resource` / `data` / `module` / `output` /
//     `check` block of each module, test code excluded.
//   - Seeds: the addresses executed assertions name -- `assert` conditions and
//     `expect_failures` entries in `tests/*.tftest.hcl`, the module's own
//     `check` blocks, and `lifecycle { pre|postcondition }` guards.
//   - Graph: `local.x`, `output.x` and `var.x` are indirections, not
//     destinations; each expands to the traversals of its value (or, for a
//     variable, of its `validation` conditions).
//   - Covered: the closure of the seeds over the graph, within the
//     denominator.
//
// Granularity is the BLOCK, not the line: a 220-line resource counts as
// covered off a single attribute assertion. That is inherent to measuring
// Terraform this way, so it is stated in the report and on stdout rather than
// disguised behind a line count that would look more precise than it is.
//
// Exit codes: 0 on every normal outcome, "nothing to measure" included -- this
// is a reporting tier, it must never break a build; 1 the report could not be
// written; 2 a command line that cannot be run, or an `--output` outside the
// repository.
package cli

import (
	"fmt"
	"io"
	"os"

	"github.com/rios0rios0/pipelines/global/scripts/languages/terraform/internal/flags"
	"github.com/rios0rios0/pipelines/global/scripts/languages/terraform/internal/paths"
	"github.com/rios0rios0/pipelines/global/scripts/languages/terraform/internal/text"
	"github.com/rios0rios0/pipelines/global/scripts/languages/terraform/terra-test/coverage/internal/domain/commands"
	"github.com/rios0rios0/pipelines/global/scripts/languages/terraform/terra-test/coverage/internal/domain/entities"
	infrastructure "github.com/rios0rios0/pipelines/global/scripts/languages/terraform/terra-test/coverage/internal/infrastructure/repositories"
)

const (
	defaultOutput  = "build/reports/terra-coverage-generic.xml"
	exitFailed     = 1
	exitOutside    = 2
	percent        = 100
	summaryPrefix  = "terra generic coverage: "
	granularityTip = summaryPrefix + "granularity is per BLOCK, not per line -- a 220-line resource counts as " +
		"covered off a single attribute assertion, so this is breadth of exercise, not depth."
	nothingTip = summaryPrefix + "nothing to measure (no module directories with .tf files found); " +
		"wrote an empty report."
)

func parser() flags.Parser {
	return flags.Parser{
		Prog: "terra-coverage",
		Description: "Emit a SonarQube generic coverage report for a Terraform module tree: which declared " +
			"blocks an assertion `terraform test` runs actually reaches.",
		Options: []flags.Option{
			{Name: "--repo-dir", Value: true, Default: ".", Help: "Repository root (default: cwd)"},
			{
				Name: "--output", Value: true, Default: defaultOutput,
				Help: "Report path (default: " + defaultOutput + ")",
			},
			{Name: "--quiet", Help: "Suppress the summary lines"},
		},
	}
}

// Run is the whole command, writing to `stdout` and `stderr` and returning
// the exit status.
func Run(arguments []string, stdout, stderr io.Writer) int {
	values, code, ok := parser().Parse(arguments, stdout, stderr)
	if !ok {
		return code
	}
	root, err := paths.Resolve(values.String("--repo-dir"))
	if err != nil {
		_, _ = fmt.Fprintf(stderr, "ERROR: %s\n", err)
		return exitFailed
	}
	output, err := paths.Resolve(paths.Join(root, values.String("--output")))
	if err != nil {
		_, _ = fmt.Fprintf(stderr, "ERROR: %s\n", err)
		return exitFailed
	}
	// `--output` is confined to the repository measured. The report describes
	// that tree and every caller writes it under `build/reports/` there;
	// following a `..` would write through the repository root and create the
	// directories on the way -- a path traversal for any caller that does not
	// choose its own arguments, a workflow interpolating a variable or an
	// agent driving this as a tool.
	if !paths.IsRelativeTo(output, root) {
		_, _ = fmt.Fprintf(stderr, "%s--output must stay inside %s, got %s\n", summaryPrefix, root, output)
		return exitOutside
	}

	result := commands.NewMeasureCoverageCommand(infrastructure.NewFilesystemModulesRepository(root)).Execute()
	for _, warning := range result.Warnings {
		_, _ = fmt.Fprintln(stderr, warning)
	}
	if err = os.MkdirAll(paths.Dir(output), text.NewDirMode); err == nil {
		err = text.Write(output, entities.Render(result.Coverage))
	}
	if err != nil {
		_, _ = fmt.Fprintf(stderr, "ERROR: %s\n", err)
		return exitFailed
	}

	if !values.Bool("--quiet") {
		share := 0
		if result.Total > 0 {
			share = result.Covered * percent / result.Total
		}
		_, _ = fmt.Fprintf(stdout, "%s%d/%d blocks (%d%%) -> %s\n",
			summaryPrefix, result.Covered, result.Total, share, output)
		_, _ = fmt.Fprintln(stdout, granularityTip)
		if result.Total == 0 {
			_, _ = fmt.Fprintln(stdout, nothingTip)
		}
	}
	return 0
}
