// Command reportuploads holds the GitHub Actions report-upload contract for
// `.github/tests/test-report-uploads.sh`, which explains why publishing a
// report must never decide whether a job passes.
//
// Run from the repository root, it reads every composite action under github/
// and every workflow under .github/workflows/, and prints one
// `<kind>\t<finding>` line per violation, where <kind> is optional, silent,
// verify or deliverable.
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
	if len(arguments) != 0 {
		_, _ = fmt.Fprintln(stderr, "usage: reportuploads (run from the repository root)")
		return exitUsage
	}
	var output strings.Builder
	err := check(".", &output)
	if err == nil {
		_, err = io.WriteString(stdout, output.String())
	}
	if err != nil {
		_, _ = fmt.Fprintf(stderr, "reportuploads: %v\n", err)
		return exitFailed
	}
	return 0
}
