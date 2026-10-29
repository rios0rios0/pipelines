// Command azurestepnames expands every Azure DevOps job the way the agent does
// before it runs one, for `.github/tests/test-azure-step-names.sh`, which
// explains why the two directions it checks must hold at once.
//
// Run from the repository root, it prints one `<assertion>\t<finding>` line per
// violation, where <assertion> is:
//
//	unreadable  a template that does not parse, or an include that points at nothing
//	duplicate   a job whose expanded steps declare one `name:` twice
//	scripts     a job using `$(Scripts.Directory)` that never includes scripts-repo
package main

import (
	"fmt"
	"io"
	"os"
	"strings"
)

func main() {
	os.Exit(run(os.Args[1:], os.Stdout, os.Stderr))
}

func run(arguments []string, stdout, stderr io.Writer) int {
	if len(arguments) != 0 {
		_, _ = fmt.Fprintln(stderr, "usage: azurestepnames (run from the repository root)")
		return exitUsage
	}
	var output strings.Builder
	err := expandAll(".", &output)
	if err == nil {
		_, err = io.WriteString(stdout, output.String())
	}
	if err != nil {
		_, _ = fmt.Fprintf(stderr, "azurestepnames: %v\n", err)
		return exitFailed
	}
	return 0
}

// The exit statuses: a check that could not run is not a check that failed.
const (
	exitFailed = 1
	exitUsage  = 2
)
