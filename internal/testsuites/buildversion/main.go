// Command buildversion answers the queries `.github/tests/test-build-version.sh`
// asks of the image delivery action and the Go workflows:
//
//	buildversion query <file> <expression>
//
// evaluates the expression over the parsed file and prints the result. A query
// that fails -- a missing key, a step no fragment matches, a file that does not
// parse -- prints its error as `<Kind: message>` instead of failing, so an
// assertion comparing the answer is a FAIL line that names the problem rather
// than a crash under `set -e`. See query.go for what an expression may say.
package main

import (
	"fmt"
	"io"
	"os"
)

// The exit statuses.
const (
	exitFailed = 1
	exitUsage  = 2
)

// queryArguments is how many arguments `query` takes, the command included.
const queryArguments = 3

func main() {
	os.Exit(run(os.Args[1:], os.Stdout, os.Stderr))
}

func run(arguments []string, stdout, stderr io.Writer) int {
	if len(arguments) != queryArguments || arguments[0] != "query" {
		_, _ = fmt.Fprintln(stderr, "usage: buildversion query <file> <expression>")
		return exitUsage
	}
	if _, err := fmt.Fprintln(stdout, answer(arguments[1], arguments[2])); err != nil {
		return exitFailed
	}
	return 0
}
