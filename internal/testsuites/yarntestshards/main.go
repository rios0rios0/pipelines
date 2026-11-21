// Command yarntestshards holds the `test_shards` contract of the Yarn workflows for
// `.github/tests/test-yarn-test-shards.sh`, which explains why each property fails quietly when it
// regresses.
//
//	yarntestshards check <repository root>
//	yarntestshards script <repository root> <job> <step name>
//	yarntestshards limit <repository root>
//
// `check` prints one `<group>\t<finding>` line per violation, where <group> names the assertion:
// input, jobs, matrix, gates, steps, handoff or docs. `script` prints the `run:` of one step of
// yarn.yaml, so the suite executes what the workflow runs. `limit` prints how many shards the
// workflow's table reaches.
package main

import (
	"fmt"
	"io"
	"os"
	"strconv"
	"strings"
)

// The exit statuses: a check that could not run is not a check that failed.
const (
	exitFailed = 1
	exitUsage  = 2
)

// How many arguments a subcommand takes after its name.
const (
	rootAlone   = 1 // the repository root
	rootAndStep = 3 // the repository root, a job, and the name of one of its steps
)

// command is one subcommand: how many arguments it takes, and what it prints.
type command struct {
	arguments int
	run       func(arguments []string, output *strings.Builder) error
}

func commands() map[string]command {
	return map[string]command{
		"check": {arguments: rootAlone, run: func(arguments []string, output *strings.Builder) error {
			return check(arguments[0], output)
		}},
		"script": {arguments: rootAndStep, run: func(arguments []string, output *strings.Builder) error {
			script, err := stepScript(arguments[0], arguments[1], arguments[2])
			output.WriteString(script)
			return err
		}},
		"limit": {arguments: rootAlone, run: func(arguments []string, output *strings.Builder) error {
			limit, err := shardLimit(arguments[0])
			output.WriteString(strconv.Itoa(limit) + "\n")
			return err
		}},
	}
}

func main() {
	os.Exit(run(os.Args[1:], os.Stdout, os.Stderr))
}

func run(arguments []string, stdout, stderr io.Writer) int {
	var selected command
	found := false
	if len(arguments) > 0 {
		selected, found = commands()[arguments[0]]
	}
	if !found || len(arguments)-1 != selected.arguments {
		_, _ = fmt.Fprintln(stderr, "usage: yarntestshards check <root> | script <root> <job> <step> | limit <root>")
		return exitUsage
	}
	var output strings.Builder
	err := selected.run(arguments[1:], &output)
	if err == nil {
		_, err = io.WriteString(stdout, output.String())
	}
	if err != nil {
		_, _ = fmt.Fprintf(stderr, "yarntestshards: %v\n", err)
		return exitFailed
	}
	return 0
}
