// Package cli is the smoke-test generator's command line: it parses the
// arguments, generates `tests/smoke.tftest.hcl` for the module and formats
// it, reporting what it did.
//
// Where a monorepo's generator treats each `modules/<name>/` as a module,
// this one treats the repository root as the single module -- the
// module-per-repository layout -- and writes one file:
//
//   - one `mock_provider "<local>" {}` for every required provider, so no
//     credentials or network are needed;
//   - one `run "smoke_plans_successfully"` with type-valid stubs for every
//     required variable;
//   - one `run "validation_rejects_invalid_<var>"` per required variable with
//     a `validation {}` block, handing it an invalid value and expecting
//     `var.<var>` to fail.
//
// An existing test whose line 1 is not the generator's marker is
// hand-written and left untouched unless `--force` is given.
//
// Exit codes: 0 generated or skipped (a formatter problem is only a
// warning); 1 a module file could not be read or the test written; 2 a
// command line that cannot be run.
package cli

import (
	"fmt"
	"io"

	"github.com/rios0rios0/pipelines/global/scripts/languages/terraform/internal/flags"
	"github.com/rios0rios0/pipelines/global/scripts/languages/terraform/internal/paths"
	"github.com/rios0rios0/pipelines/global/scripts/languages/terraform/tftest-gen/internal/domain/commands"
	"github.com/rios0rios0/pipelines/global/scripts/languages/terraform/tftest-gen/internal/domain/repositories"
	infrastructure "github.com/rios0rios0/pipelines/global/scripts/languages/terraform/tftest-gen/internal/infrastructure/repositories"
)

const exitFailed = 1

func parser() flags.Parser {
	return flags.Parser{
		Prog: "tftest-gen",
		Description: "Generate tests/smoke.tftest.hcl for a single terraform-module repository: mocked " +
			"providers, a plan-time smoke run, and one run per validated required variable.",
		Options: []flags.Option{
			{Name: "--repo-dir", Value: true, Default: ".", Help: "Path to the module repo root (default: cwd)"},
			{Name: "--force", Help: "Overwrite even hand-written tests (dangerous)"},
		},
	}
}

// Run is the whole command, writing to `stdout` and `stderr` and returning
// the exit status.
func Run(arguments []string, stdout, stderr io.Writer) int {
	return RunWith(arguments, stdout, stderr, func(root string) repositories.Formatter {
		return infrastructure.NewTerraformFormatter(root)
	})
}

// RunWith is Run with the formatter chosen by the caller.
func RunWith(
	arguments []string, stdout, stderr io.Writer, formatter func(root string) repositories.Formatter,
) int {
	values, code, ok := parser().Parse(arguments, stdout, stderr)
	if !ok {
		return code
	}
	root, err := paths.Resolve(values.String("--repo-dir"))
	if err != nil {
		_, _ = fmt.Fprintf(stderr, "ERROR: %s\n", err)
		return exitFailed
	}
	repository := infrastructure.NewFilesystemModuleRepository(root)
	result, err := commands.NewGenerateSmokeTestsCommand(repository).Execute(values.Bool("--force"))
	if err != nil {
		_, _ = fmt.Fprintf(stderr, "ERROR: %s\n", err)
		return exitFailed
	}
	if result.Skipped {
		_, _ = fmt.Fprintf(stdout, "SKIP hand-written smoke at %s (use --force to overwrite)\n",
			repository.SmokeTestPath())
		return 0
	}
	_, _ = fmt.Fprintf(stdout, "wrote %s (providers=%d, vars=%d, validations=%d)\n",
		repository.SmokeTestPath(), result.Providers, result.Variables, result.Validations)
	if warning := formatter(root).Format(); warning != "" {
		_, _ = fmt.Fprintf(stderr, "warning: %s\n", warning)
	}
	return 0
}
