// Command codeqlgate holds the two YAML-shaped contracts of
// `.github/tests/test-codeql-gate.sh`, which explains why each exists:
//
//	codeqlgate composite <action.yaml> <repository root>
//	    the GitHub composite analyses, gates, then uploads at best
//	codeqlgate own-scan <repository root>
//	    this repository's own scan narrows nothing it has not explained
//
// Each prints one line per violation. A file it cannot read is printed as a
// violation too, so the assertion that reads the output can never pass on a
// check that did not run.
package main

import (
	"errors"
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

const usage = "usage: codeqlgate composite <action.yaml> <repository root> | own-scan <repository root>"

// The argument counts of the two commands.
const (
	compositeArguments = 3
	ownScanArguments   = 2
)

// errUsage is arguments that name no command.
var errUsage = errors.New(usage)

func main() {
	os.Exit(run(os.Args[1:], os.Stdout, os.Stderr))
}

func run(arguments []string, stdout, stderr io.Writer) int {
	var output strings.Builder
	err := dispatch(arguments, &output)
	if errors.Is(err, errUsage) {
		_, _ = fmt.Fprintln(stderr, usage)
		return exitUsage
	}
	if err != nil {
		output.WriteString("could not run the check: " + err.Error() + "\n")
	}
	if _, writeErr := io.WriteString(stdout, output.String()); writeErr != nil || err != nil {
		return exitFailed
	}
	return 0
}

func dispatch(arguments []string, output io.Writer) error {
	if len(arguments) == ownScanArguments && arguments[0] == "own-scan" {
		return checkOwnScan(arguments[1], output)
	}
	if len(arguments) != compositeArguments || arguments[0] != "composite" {
		return errUsage
	}
	return checkComposite(arguments[1], arguments[2], output)
}
