// Package cli is the ordering checker's command line: it parses the
// arguments, checks -- or with `--fix` rewrites -- the repository, writes the
// JUnit report and prints every finding.
//
// The team orders the dense `variables.tf` / `providers.tf` / `outputs.tf` /
// `*.hcl` files of its Terragrunt monorepos -- numbered dependency layers
// under `environments/`, root modules under `stacks/`, leaf modules under
// `modules/` -- by one convention, enforced here as a CI gate plus an
// idempotent formatter:
//
//   - A. `environments/**/root.hcl`: `dependency` blocks ascending by the
//     `environments/NN_` number of each `config_path`.
//   - B. `environments/**/root.hcl`: the `inputs = {}` assignments grouped by
//     dependency, groups ascending by number; locals and tags first, literals
//     last.
//   - C. `stacks/*/variables.tf`: a `// SET ON .HCL` section before a
//     `// SET ON .ENV` one; inside `.HCL`, the variables a dependency feeds
//     ordered by its number.
//   - D. `**/providers.tf`: `required_providers` entries and `provider` blocks
//     heaviest to lightest by the ranking.
//   - E. `stacks/*/outputs.tf`: outputs in the declaration order, in
//     `main*.tf`, of the first module or resource each references.
//   - F. terragrunt inputs: every key of an `inputs = {}` -- in a `root.hcl` or
//     a leaf `terragrunt.hcl` -- declared as a `variable` in its stack.
//
// `--fix` never drops, duplicates or corrupts content: it parses each region
// into exact substrings, verifies they reproduce the region byte for byte,
// and only then permutes them; a region that does not round-trip is reported
// and left alone. Rule F is check-only for the same reason -- deleting a dead
// input is not a permutation.
//
// Exit codes: 0 no ordering errors remain (after `--fix`, if given); 1 an
// error remains, or a file, the config or the report directory could not be
// used; 2 a command line that cannot be run.
package cli

import (
	"errors"
	"fmt"
	"io"
	"os"
	"strings"

	"github.com/rios0rios0/pipelines/global/scripts/languages/terraform/internal/flags"
	"github.com/rios0rios0/pipelines/global/scripts/languages/terraform/internal/paths"
	"github.com/rios0rios0/pipelines/global/scripts/languages/terraform/internal/text"
	"github.com/rios0rios0/pipelines/global/scripts/languages/terraform/order-check/internal/domain/commands"
	"github.com/rios0rios0/pipelines/global/scripts/languages/terraform/order-check/internal/domain/entities"
	"github.com/rios0rios0/pipelines/global/scripts/languages/terraform/order-check/internal/infrastructure/reports"
	infrastructure "github.com/rios0rios0/pipelines/global/scripts/languages/terraform/order-check/internal/infrastructure/repositories"
)

const (
	exitFailed = 1
	configName = ".terraform-order.json"
	fixTip     = "  Tip: run your formatter to normalize alignment " +
		"(`terra format`, or `terraform fmt -recursive` + `terragrunt hcl format`)."
)

func parser() flags.Parser {
	report, found := os.LookupEnv("REPORT_PATH")
	if !found {
		report = "build/reports"
	}
	return flags.Parser{
		Prog:        "order-check",
		Description: "Check/auto-fix Terragrunt file ordering.",
		Options: []flags.Option{
			{Name: "--fix", Help: "rewrite files into the canonical order instead of only reporting"},
			{Name: "--repo-dir", Value: true, Default: ".", Help: "repository root to scan (default: cwd)"},
			{Name: "--config", Value: true, Help: "path to .terraform-order.json"},
			{Name: "--report", Value: true, Default: report, Help: "directory for the JUnit report"},
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
		return failed(stderr, err)
	}
	if !paths.IsDir(root) {
		_, _ = fmt.Fprintf(stderr, "ERROR: repo dir not found: %s\n", root)
		return exitFailed
	}
	config, err := loadConfig(root, values.String("--config"))
	if err != nil {
		return failed(stderr, err)
	}
	fix := values.Bool("--fix")
	results, err := commands.NewCheckOrderCommand(infrastructure.NewFilesystemWorkspaceRepository(root), config).
		Execute(fix)
	if err == nil {
		err = reports.Write(results, paths.Join(root, values.String("--report")), root)
	}
	var outside *reports.OutsideError
	if errors.As(err, &outside) {
		_, _ = fmt.Fprintln(stderr, outside.Message)
		return exitFailed
	}
	if err != nil {
		return failed(stderr, err)
	}
	return summarise(results, fix, stdout, stderr)
}

func failed(stderr io.Writer, err error) int {
	_, _ = fmt.Fprintf(stderr, "ERROR: %s\n", err)
	return exitFailed
}

// loadConfig reads `--config`, relative to the working directory, or the
// repository's `.terraform-order.json`; the built-in ranking when neither is
// a file.
func loadConfig(root, explicit string) (entities.Config, error) {
	path := paths.Join(root, configName)
	if explicit != "" {
		path = explicit
	}
	if !paths.IsFile(path) {
		return entities.NewConfig(entities.DefaultProviderOrder()), nil
	}
	source, err := text.ReadStrict(path)
	if err != nil {
		return entities.Config{}, err
	}
	return entities.ParseConfig([]byte(source))
}

// summarise prints every finding -- errors on stderr, warnings on stdout --
// and the verdict.
func summarise(results []entities.FileResult, fix bool, stdout, stderr io.Writer) int {
	errorCount, warnings, fixed := 0, 0, 0
	failing := map[string]bool{}
	for _, result := range results {
		for _, finding := range result.Findings {
			line := "  " + strings.ToUpper(string(finding.Severity)) + ": [" + finding.Rule + "] " +
				finding.Path + ": " + finding.Message
			if finding.Severity == entities.SeverityError {
				_, _ = fmt.Fprintln(stderr, line)
				errorCount++
				failing[result.Path] = true
			} else {
				_, _ = fmt.Fprintln(stdout, line)
				warnings++
			}
		}
		if result.Fixed {
			fixed++
			_, _ = fmt.Fprintf(stdout, "  FIXED: %s\n", result.Path)
		}
	}
	if fix {
		_, _ = fmt.Fprintf(stdout, "\norder-check: rewrote %d file(s); %d unfixable error(s), %d warning(s).\n",
			fixed, errorCount, warnings)
		if fixed > 0 {
			// Reordering `root.hcl` inputs changes the `=` alignment of each
			// group; the `.tf` reordering is already fmt-clean. Alignment is left
			// to the repository's formatter, the one the code-check stage enforces.
			_, _ = fmt.Fprintln(stdout, fixTip)
		}
		if errorCount > 0 {
			return exitFailed
		}
		return 0
	}
	if errorCount > 0 {
		_, _ = fmt.Fprintf(stderr, "\norder-check: %d ordering error(s) across %d file(s). "+
			"Run with --fix to auto-sort. (%d warning(s).)\n", errorCount, len(failing), warnings)
		return exitFailed
	}
	_, _ = fmt.Fprintf(stdout, "order-check: no ordering errors. (%d warning(s).)\n", warnings)
	return 0
}
