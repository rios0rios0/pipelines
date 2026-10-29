// Command workflowcomposition runs the checks `.github/tests/test-workflow-composition.sh` cannot
// express as line shapes: the fact table its first nine tests look up, and the assertions that
// read a PARSED pipeline file (Tests 10 to 17). It is test support, built by that suite from this
// checkout and never shipped to a consumer.
//
// Usage:
//
//	workflowcomposition <check> <directory>
//
// Each check reads the directory it is given (`.github/workflows`, or the repository root for
// `advisory-twin`) and prints one finding per line; no output means the assertion holds. A problem
// with one file is a finding about that file, never a failure of the command, because the suite
// runs under `set -e` and a failing command would end it without a verdict. The command fails
// only when it is called wrongly or cannot write its output, and `facts` also when a workflow
// cannot be read at all, since a fact table missing a file would let every lookup into it pass.
package main

import (
	"bufio"
	"fmt"
	"io"
	"os"
	"sort"
	"strings"
)

const (
	exitFailed = 1
	exitUsage  = 2
	arguments  = 2
)

// check is one of the suite's assertions over the tree under `directory`.
type check func(directory string, out *printer) error

// checks maps each subcommand to its assertion, named for the suite's variable it fills.
func checks() map[string]check {
	return map[string]check{
		"facts":          writeFacts,         // FACTS, Tests 1-9
		"runs-on":        checkRunsOn,        // BAD_RUNS_ON, Test 10
		"trigger":        checkTrigger,       // BAD_TRIGGER, Test 11
		"on-expression":  checkOnExpressions, // BAD_ON_EXPRESSION, Test 12
		"claude-tools":   checkClaudeTools,   // BAD_CLAUDE_TOOLS, Test 13
		"review-guard":   checkReviewGuard,   // BAD_REVIEW_GUARD, Test 14
		"cancel-gate":    checkCancelGate,    // BAD_CANCEL_GATE, Test 15
		"advisory-job":   checkAdvisoryJobs,  // BAD_ADVISORY_JOB, Test 16
		"advisory-twin":  checkAdvisoryTwins, // BAD_ADVISORY_TWIN, Test 16
		"packages-grant": checkPackagesGrant, // BAD_PACKAGES_GRANT, Test 17
	}
}

func main() {
	os.Exit(run(os.Args[1:], os.Stdout, os.Stderr))
}

// run is the whole command: it runs the check `argv` names and returns the exit status.
func run(argv []string, stdout, stderr io.Writer) int {
	available := checks()
	if len(argv) != arguments {
		return usage(stderr, available)
	}
	selected, ok := available[argv[0]]
	if !ok {
		return usage(stderr, available)
	}
	buffered := bufio.NewWriter(stdout)
	out := &printer{out: buffered}
	err := selected(argv[1], out)
	if err == nil {
		err = out.err
	}
	if flushErr := buffered.Flush(); err == nil {
		err = flushErr
	}
	if err != nil {
		_, _ = fmt.Fprintf(stderr, "workflowcomposition %s: %v\n", argv[0], err)
		return exitFailed
	}
	return 0
}

func usage(stderr io.Writer, available map[string]check) int {
	names := make([]string, 0, len(available))
	for name := range available {
		names = append(names, name)
	}
	sort.Strings(names)
	_, _ = fmt.Fprintf(stderr, "usage: workflowcomposition <%s> <directory>\n", strings.Join(names, "|"))
	return exitUsage
}

// printer writes a check's output one line at a time and keeps the first write error, so a check
// prints as it goes and a broken stdout is reported once, at the end.
type printer struct {
	out io.Writer
	err error
}

// line prints one line of output.
func (p *printer) line(text string) {
	if p.err == nil {
		_, p.err = io.WriteString(p.out, text+"\n")
	}
}
