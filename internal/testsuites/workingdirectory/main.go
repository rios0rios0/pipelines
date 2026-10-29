// Command workingdirectory pins the `working_directory` contract on the
// reusable workflows and composite stages that accept it, for
// `.github/tests/test-working-directory.sh`, which explains why each property
// fails quietly when it regresses.
//
//	workingdirectory <repository root>
//
// prints one `<group>\t<finding>` line per violation, where <group> names the
// assertion: declared, forwarded, repository_wide, threaded, report_paths,
// ruby_version or sonar.
package main

import (
	"fmt"
	"io"
	"os"
	"strings"
)

// The exit statuses: a check that could not run is not a check that failed.
const (
	exitFailed = 1
	exitUsage  = 2
)

func main() {
	os.Exit(run(os.Args[1:], os.Stdout, os.Stderr))
}

func run(arguments []string, stdout, stderr io.Writer) int {
	if len(arguments) != 1 {
		_, _ = fmt.Fprintln(stderr, "usage: workingdirectory <repository root>")
		return exitUsage
	}
	var output strings.Builder
	err := check(arguments[0], &output)
	if err == nil {
		_, err = io.WriteString(stdout, output.String())
	}
	if err != nil {
		_, _ = fmt.Fprintf(stderr, "workingdirectory: %v\n", err)
		return exitFailed
	}
	return 0
}
