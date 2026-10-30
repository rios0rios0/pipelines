// Command runnercachegating finds every GitHub Actions cache that would restore
// into a `$HOME` path on a self-hosted runner, for
// `.github/tests/test-runner-cache-gating.sh`, which explains why such a cache
// fails there and what it costs.
//
//	runnercachegating <directory>
//
// prints one `<file>:<line>: <finding>` line per violation in the YAML files
// under the directory, and nothing at all when they are clean, so the same
// program serves the real tree and the suite's deliberate-violation fixtures.
//
// It reads the files as indented text rather than parsing them: every finding
// is about a step's own keys, which the indentation answers. A step written in
// flow style would slip past it; none is.
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
		_, _ = fmt.Fprintln(stderr, "usage: runnercachegating <directory>")
		return exitUsage
	}
	findings, err := scan(arguments[0])
	if err == nil {
		var output strings.Builder
		for _, finding := range findings {
			output.WriteString(finding + "\n")
		}
		_, err = io.WriteString(stdout, output.String())
	}
	if err != nil {
		_, _ = fmt.Fprintf(stderr, "runnercachegating: %v\n", err)
		return exitFailed
	}
	return 0
}
