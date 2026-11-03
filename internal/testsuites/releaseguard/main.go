// Command releaseguard reads the deployment workflows for
// `.github/tests/test-release-guard.sh`, which explains what the release guard
// is for:
//
//	releaseguard wiring <directory>
//
// prints one finding per line about every workflow in the directory that
// deploys through a `50-deployment/<provider>` action without the release
// guard wired the one way that holds, and nothing when every one is. It reads
// the PARSED documents: the gate is a conjunct of a free-text `if:`, which a
// reformat can spread over several lines or move into a clause of its own.
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

const usage = "usage: releaseguard wiring <directory>"

// wiringArguments is the command and the directory it reads.
const wiringArguments = 2

func main() {
	os.Exit(run(os.Args[1:], os.Stdout, os.Stderr))
}

func run(arguments []string, stdout, stderr io.Writer) int {
	if len(arguments) != wiringArguments || arguments[0] != "wiring" {
		_, _ = fmt.Fprintln(stderr, usage)
		return exitUsage
	}
	findings, err := wiring(arguments[1])
	if err == nil {
		var output strings.Builder
		for _, finding := range findings {
			output.WriteString(finding + "\n")
		}
		_, err = io.WriteString(stdout, output.String())
	}
	if err != nil {
		_, _ = fmt.Fprintf(stderr, "releaseguard: %v\n", err)
		return exitFailed
	}
	return 0
}
