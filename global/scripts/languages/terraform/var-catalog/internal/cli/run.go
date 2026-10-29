// Package cli is the shared-variable generator's command line: it parses the
// arguments, runs the generator against the checkout and turns its result
// into the lines a person or a CI log reads and an exit status.
//
// A Terragrunt repository is a set of root modules, so an input every stack
// receives has to be DECLARED in every stack. That is inherent to the layout,
// but the declarations are not: measured across one four-repository fabric,
// `environment` was declared 47 times, `cloudflare_api_token` 27, and the
// bodies had drifted into near-copies of each other -- worse than one shared
// body or 47 deliberate ones, because nobody can tell which differences are
// meaningful. This keeps ONE canonical body per name in a per-repository
// catalog and writes the subset each stack actually uses into
// `stacks/<stack>/variables-shared.tf`.
//
// The output is generated and COMMITTED rather than emitted by a Terragrunt
// `generate` block, because three CI gates read the source tree without going
// through Terragrunt: the order-check's dead-input scan, the opt-in
// `terraform validate` tier, and AST-based tests.
//
// Exit codes: 0 done (or nothing to do); 1 `--check` found an out-of-date
// file, or a file could not be read or written; 2 a command line that cannot
// be run.
package cli

import (
	"fmt"
	"io"

	"github.com/rios0rios0/pipelines/global/scripts/languages/terraform/internal/flags"
	"github.com/rios0rios0/pipelines/global/scripts/languages/terraform/internal/paths"
	"github.com/rios0rios0/pipelines/global/scripts/languages/terraform/var-catalog/internal/domain/commands"
	"github.com/rios0rios0/pipelines/global/scripts/languages/terraform/var-catalog/internal/domain/entities"
	infrastructure "github.com/rios0rios0/pipelines/global/scripts/languages/terraform/var-catalog/internal/infrastructure/repositories"
)

const (
	exitDone   = 0
	exitFailed = 1
	prefix     = "var-catalog: "
)

func parser() flags.Parser {
	return flags.Parser{
		Prog: "var-catalog",
		Description: "Generate (or verify) the shared `variable` declarations each stack needs, " +
			"from the repository's .terraform-var-catalog.hcl.",
		Options: []flags.Option{
			{Name: "--repo-dir", Value: true, Default: ".", Help: "repository root (default: the working directory)"},
			{Name: "--check", Help: "fail if a committed generated file is out of date; write nothing (the CI gate)"},
			{Name: "--report", Help: "print what would change; write nothing, fail nothing"},
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
		_, _ = fmt.Fprintf(stderr, "%sERROR: %s\n", prefix, err)
		return exitFailed
	}
	check, report := values.Bool("--check"), values.Bool("--report")
	mode := commands.ModeWrite
	if check {
		mode = commands.ModeCheck
	} else if report {
		mode = commands.ModeReport
	}
	repository := infrastructure.NewFilesystemStacksRepository(root)
	result, err := commands.NewGenerateSharedVariablesCommand(repository).Execute(mode)
	if err != nil {
		_, _ = fmt.Fprintf(stderr, "%sERROR: %s\n", prefix, err)
		return exitFailed
	}
	if result.NoCatalog {
		_, _ = fmt.Fprintf(stdout, "%sno %s in %s; nothing to do\n", prefix, entities.CatalogName, root)
		return exitDone
	}
	return summarise(result, check, report, stdout, stderr)
}

// summarise writes what the run found. The PRESERVED lines are left out of
// `--check`: that mode's output is quoted verbatim into a CI failure message,
// and burying the one actionable line under a dozen informational ones is how
// a good message stops being read.
func summarise(result commands.Result, check, report bool, stdout, stderr io.Writer) int {
	if !check {
		for _, entry := range result.Preserved {
			_, _ = fmt.Fprintf(stdout, "%sPRESERVED hand-written declaration -- %s\n", prefix, entry)
		}
	}
	switch {
	case check && len(result.Drift) > 0:
		_, _ = fmt.Fprintf(stderr, "%sgenerated files are out of date:\n", prefix)
		for _, file := range result.Drift {
			_, _ = fmt.Fprintf(stderr, "  %s\n", file)
		}
		_, _ = fmt.Fprintln(stderr, "re-run the var-catalog runner and commit the result")
		return exitFailed
	case report:
		_, _ = fmt.Fprintf(stdout, "%s%d file(s) would change\n", prefix, len(result.Drift))
		for _, file := range result.Drift {
			_, _ = fmt.Fprintf(stdout, "  %s\n", file)
		}
	case check:
		_, _ = fmt.Fprintf(stdout, "%sgenerated files are up to date\n", prefix)
	default:
		_, _ = fmt.Fprintf(stdout, "%swrote %d file(s)\n", prefix, result.Written)
	}
	return exitDone
}
