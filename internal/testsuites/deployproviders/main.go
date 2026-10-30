// Command deployproviders reads the deployment workflows for
// `.github/tests/test-deploy-providers.sh`, which explains what each answer
// guards:
//
//	deployproviders require-checks-needs <workflow>...
//	    one `<file name>\t<needs>` line for every step running the require-checks gate
//	deployproviders secrets-step <workflow>
//	    the script of the first step gated on BUILD_ENV_SECRETS
//	deployproviders input-off <workflow> <input>
//	    exits 0 when the workflow_call input is a boolean that defaults to false
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

const usage = "usage: deployproviders require-checks-needs <workflow>... | secrets-step <workflow> | " +
	"input-off <workflow> <input>"

// The argument counts of the commands that take a fixed number.
const (
	secretsStepArguments = 2
	inputOffArguments    = 3
)

var (
	// errUsage is arguments that name no command.
	errUsage = errors.New(usage)
	// errFailed is a check that ran and did not hold.
	errFailed = errors.New("the check does not hold")
)

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
	case errors.Is(err, errFailed):
		return exitFailed
	}
	_, _ = fmt.Fprintf(stderr, "deployproviders: %v\n", err)
	return exitFailed
}

func dispatch(arguments []string, output io.Writer) error {
	if len(arguments) > 1 && arguments[0] == "require-checks-needs" {
		return requireChecksNeeds(arguments[1:], output)
	}
	if len(arguments) == secretsStepArguments && arguments[0] == "secrets-step" {
		return secretsStep(arguments[1], output)
	}
	if len(arguments) != inputOffArguments || arguments[0] != "input-off" {
		return errUsage
	}
	return inputOff(arguments[1], arguments[2])
}
