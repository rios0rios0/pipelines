// Package reports writes the ordering checker's JUnit report, which every
// platform publishes to its Tests tab.
package reports

import (
	"fmt"
	"os"
	"strconv"
	"strings"

	"github.com/rios0rios0/pipelines/global/scripts/languages/terraform/internal/paths"
	"github.com/rios0rios0/pipelines/global/scripts/languages/terraform/internal/text"
	"github.com/rios0rios0/pipelines/global/scripts/languages/terraform/order-check/internal/domain/entities"
)

// FileName is the report every template publishes.
const FileName = "junit-order-check.xml"

// OutsideError is a report directory, or report file, outside the
// repository. Its message is the whole report of it.
type OutsideError struct {
	Message string
}

func (e *OutsideError) Error() string {
	return e.Message
}

// Render is the JUnit document: one test case per reported file, failing
// when the file has an error, its warnings as the case's output otherwise.
func Render(results []entities.FileResult) string {
	cases := make([]string, 0, len(results))
	failures := 0
	for _, result := range results {
		var errorsFound, warnings []string
		for _, finding := range result.Findings {
			line := "[" + finding.Rule + "] " + finding.Message
			if finding.Severity == entities.SeverityError {
				errorsFound = append(errorsFound, line)
			} else {
				warnings = append(warnings, line)
			}
		}
		open := `    <testcase classname="order-check" name="` + text.EscapeXML(result.Path) + `">`
		switch {
		case len(errorsFound) > 0:
			failures++
			cases = append(
				cases,
				open+`<failure message="`+text.EscapeXML(strings.Join(errorsFound, "; "))+`"/></testcase>`,
			)
		case len(warnings) > 0:
			cases = append(
				cases,
				open+"<system-out>"+text.EscapeXML(strings.Join(warnings, "; "))+"</system-out></testcase>",
			)
		default:
			cases = append(cases, open+"</testcase>")
		}
	}
	counts := `tests="` + strconv.Itoa(len(results)) + `" failures="` + strconv.Itoa(failures) + `"`
	return `<?xml version="1.0" encoding="UTF-8"?>` + "\n" +
		`<testsuites name="order-check" ` + counts + ">\n" +
		`  <testsuite name="order-check" ` + counts + ">\n" +
		strings.Join(cases, "\n") + "\n" +
		"  </testsuite>\n</testsuites>\n"
}

// Write writes the report into `directory`, which must resolve inside the
// repository: `--report` arrives on the command line and the checker CREATES
// it, so "wherever you point me" is the wrong contract for a CI gate. A
// relative directory already resolves against the repository, and every
// runner passes a relative `REPORT_PATH`, so confining an absolute one costs
// nothing real and makes a traversal fail here rather than somewhere
// surprising. Both the directory and the file are resolved first, so a
// symlink cannot step outside after the check.
func Write(results []entities.FileResult, directory, repository string) error {
	base, err := paths.Resolve(repository)
	if err != nil {
		return err
	}
	resolved, err := paths.Resolve(directory)
	if err != nil {
		return err
	}
	if !paths.IsRelativeTo(resolved, base) {
		return &OutsideError{Message: fmt.Sprintf(
			"refusing to use '%s' as the report directory: it resolves outside the repository '%s'", directory, base)}
	}
	if err = os.MkdirAll(resolved, text.NewDirMode); err != nil {
		return err
	}
	file, err := paths.Resolve(paths.Join(resolved, FileName))
	if err != nil {
		return err
	}
	if paths.Dir(file) != resolved {
		return &OutsideError{Message: fmt.Sprintf("refusing to write the JUnit report outside '%s'", resolved)}
	}
	return text.Write(file, Render(results))
}
