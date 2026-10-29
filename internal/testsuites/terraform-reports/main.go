// Command terraform-reports checks an XML report the Terraform tiers wrote,
// for the shell suites under .github/tests that assert on one:
//
//	terraform-reports well-formed FILE
//	terraform-reports root FILE NAME [ATTRIBUTE=VALUE ...] [children=N]
//	terraform-reports ascending-lines FILE
//
// It exits 0 when the report is as asked, 1 when it is not -- saying why on
// stderr -- and 2 for a command line it cannot run. The suites build it once
// per run; it is test tooling, never shipped to a consumer.
package main

import (
	"fmt"
	"io"
	"os"

	"github.com/rios0rios0/pipelines/internal/testsuites/terraform-reports/internal/reports"
)

const (
	exitMismatch = 1
	exitUsage    = 2
	minimum      = 2
)

func main() {
	os.Exit(run(os.Args[1:], os.Stderr))
}

func run(arguments []string, stderr io.Writer) int {
	if len(arguments) < minimum {
		_, _ = fmt.Fprintln(stderr, "usage: terraform-reports well-formed|root|ascending-lines FILE [...]")
		return exitUsage
	}
	command, path := arguments[0], arguments[1]
	data, err := os.ReadFile(path) //nolint:gosec // test tooling reads the report its calling suite names

	if err != nil {
		_, _ = fmt.Fprintln(stderr, err)
		return exitMismatch
	}
	root, err := reports.Parse(data)
	if err == nil {
		err = check(command, root, arguments[minimum:])
	}
	if err != nil {
		_, _ = fmt.Fprintf(stderr, "%s: %s\n", path, err)
		return exitMismatch
	}
	return 0
}

func check(command string, root *reports.Element, rest []string) error {
	switch command {
	case "well-formed":
		return nil
	case "root":
		if len(rest) == 0 {
			return fmt.Errorf("%w: root needs the element name", reports.ErrMismatch)
		}
		return reports.ExpectRoot(root, rest[0], rest[1:])
	case "ascending-lines":
		return reports.ExpectAscendingLines(root)
	default:
		return fmt.Errorf("%w: unknown check %q", reports.ErrMismatch, command)
	}
}
