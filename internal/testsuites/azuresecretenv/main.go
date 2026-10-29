// Command azuresecretenv holds the Azure DevOps secret-passing contract for
// `.github/tests/test-azure-secret-env.sh`, which explains why each rule exists.
//
//	azuresecretenv check
//	    run from the repository root; prints one `<assertion>\t<finding>` line
//	    per violation, where <assertion> is parse, unmapped, classified or macro
//	azuresecretenv step-script <template> <job> <displayName>
//	    prints the script of that job's step, as the agent would run it
package main

import (
	"errors"
	"fmt"
	"io"
	"os"
	"strings"
)

const usage = "usage: azuresecretenv check | step-script <template> <job> <displayName>"

// The exit statuses: a check that could not run is not a check that failed.
const (
	exitFailed = 1
	exitUsage  = 2
)

// stepScriptArguments is how many arguments `step-script` takes.
const stepScriptArguments = 3

func main() {
	os.Exit(run(os.Args[1:], os.Stdout, os.Stderr))
}

func run(arguments []string, stdout, stderr io.Writer) int {
	var output strings.Builder
	err := dispatch(arguments, &output)
	if err == nil {
		_, err = io.WriteString(stdout, output.String())
	}
	switch {
	case err == nil:
		return 0
	case errors.Is(err, errUsage):
		_, _ = fmt.Fprintln(stderr, usage)
		return exitUsage
	}
	_, _ = fmt.Fprintf(stderr, "azuresecretenv: %v\n", err)
	return exitFailed
}

// errUsage is arguments that name no command.
var errUsage = errors.New(usage)

func dispatch(arguments []string, output io.Writer) error {
	if len(arguments) == 1 && arguments[0] == "check" {
		return check(".", output)
	}
	if len(arguments) != stepScriptArguments+1 || arguments[0] != "step-script" {
		return errUsage
	}
	return stepScript(arguments[1], arguments[2], arguments[3], output)
}
