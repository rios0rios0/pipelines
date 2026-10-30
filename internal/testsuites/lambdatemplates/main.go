// Command lambdatemplates validates the Azure DevOps Go Lambda templates and
// their example project for `.github/tests/test-lambda-templates.sh`. Run from
// the repository root:
//
//	lambdatemplates syntax       every Lambda template parses
//	lambdatemplates structure    the main and stage templates carry their keys
//	lambdatemplates parameters   every parameter a main template references is defined
//	lambdatemplates sam <file>   a SAM template, CloudFormation's tags accepted, with its keys
//	lambdatemplates yaml <file>  the file is YAML
//	lambdatemplates json <file>  the file is JSON
//
// The first three print a line per template and exit 1 when one fails; the
// last three print nothing and answer with their exit status alone.
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

const usage = "usage: lambdatemplates syntax | structure | parameters | sam <file> | yaml <file> | json <file>"

// errFailed is a check that ran and found a problem it already reported.
var errFailed = errors.New("the check failed")

func main() {
	os.Exit(run(os.Args[1:], os.Stdout, os.Stderr))
}

func run(arguments []string, stdout, stderr io.Writer) int {
	var output strings.Builder
	err := dispatch(arguments, &output)
	if _, writeErr := io.WriteString(stdout, output.String()); writeErr != nil && err == nil {
		err = writeErr
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
	_, _ = fmt.Fprintf(stderr, "lambdatemplates: %v\n", err)
	return exitFailed
}

// errUsage is arguments that name no command.
var errUsage = errors.New(usage)

func dispatch(arguments []string, output io.Writer) error {
	if len(arguments) == 1 {
		switch arguments[0] {
		case "syntax":
			return checkSyntax(".", output)
		case "structure":
			return checkStructure(".", output)
		case "parameters":
			return checkParameters(".", output)
		}
		return errUsage
	}
	if len(arguments) != fileCommandArguments {
		return errUsage
	}
	switch arguments[0] {
	case "sam":
		return checkSAM(arguments[1])
	case "yaml":
		return checkYAML(arguments[1])
	case "json":
		return checkJSON(arguments[1])
	}
	return errUsage
}

// fileCommandArguments is how many arguments a command checking one file takes.
const fileCommandArguments = 2
