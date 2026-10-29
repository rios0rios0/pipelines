package main

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"unicode/utf8"
)

// The line shapes the fact table is read from. Tests 1 to 9 are about the shape of a line -- a
// job key at two spaces, a `name:` at four -- rather than about a resolved document, so these read
// each workflow as indented text, the way `order-check` and `var-catalog` read theirs.
var (
	factJobKey       = regexp.MustCompile(`^  ([A-Za-z0-9_-]+):` + space + `*$`)
	factStageComment = regexp.MustCompile(`^  # (` + word + `+) stage` + space + `*$`)
	factName         = regexp.MustCompile(`^    name:` + space + `*'?([^']*)'?` + space + `*$`)
	factWorkflowCall = regexp.MustCompile(`^` + space + `+workflow_call:`)
	factWorkflowRun  = regexp.MustCompile(`^` + space + `+workflow_run:`)
	// `uses:` may sit at the job level (a called workflow) or inside a step. Third-party actions
	// are pinned to a full commit SHA with the human-readable version in a trailing `# vX.Y.Z`
	// comment, so the reference is captured WITHOUT anchoring at the end of the line. Anchoring
	// there silently dropped every pinned `uses:` from the table once, which made Tests 3, 6 and 7
	// pass by having nothing left to check rather than by the invariant holding.
	factUses = regexp.MustCompile(
		`^` + space + `*-?` + space + `*uses:` + space + `*'?([^'` + spaceClass + `]+?)'?(?:` + space + `+#.*)?` +
			space + `*$`)
)

// factJobKeys are the job-level keys Tests 5 and 6 look for, each emitted as `job-has-<key>`.
func factJobKeys() []string {
	return []string{"needs", "environment", "permissions", "if"}
}

// writeFacts prints the fact table every assertion of Tests 1 to 9 is a lookup into: one
// `<kind>\t<workflow>\t<job>\t<detail>` line per fact, in one pass over every `*.yaml` in the
// directory, dot files included.
func writeFacts(directory string, out *printer) error {
	entries, err := os.ReadDir(directory)
	if err != nil {
		return err
	}
	for _, entry := range entries {
		if !strings.HasSuffix(entry.Name(), ".yaml") {
			continue
		}
		if err = writeFileFacts(directory, entry.Name(), out); err != nil {
			return err
		}
	}
	return nil
}

// writeFileFacts prints the facts of one workflow.
func writeFileFacts(directory, name string, out *printer) error {
	// The directory is the checkout the suite names, and the files are what it lists.
	data, err := os.ReadFile(filepath.Join(directory, name)) //nolint:gosec // G703: reading them is the check
	if err != nil {
		return err
	}
	if !utf8.Valid(data) {
		return fmt.Errorf("%s is not UTF-8 text", name)
	}
	reader := factReader{out: out, workflow: name}
	for _, line := range splitLines(string(data)) {
		reader.read(line)
	}
	return nil
}

// factReader reads one workflow a line at a time: the trigger block until `jobs:`, then the jobs.
type factReader struct {
	out      *printer
	workflow string
	inJobs   bool
	job      string
	stage    string
}

func (r *factReader) emit(kind, job, detail string) {
	r.out.line(strings.Join([]string{kind, r.workflow, job, detail}, "\t"))
}

func (r *factReader) read(line string) {
	if strings.HasPrefix(line, "jobs:") {
		r.inJobs = true
		return
	}
	if !r.inJobs {
		r.readTrigger(line)
		return
	}
	if stage := factStageComment.FindStringSubmatch(line); stage != nil {
		r.stage = stage[1]
		return
	}
	if job := factJobKey.FindStringSubmatch(line); job != nil {
		r.job = job[1]
		r.emit("job", r.job, r.stage)
		r.stage = ""
		return
	}
	if r.job == "" {
		return
	}
	if display := factName.FindStringSubmatch(line); display != nil {
		r.emit("job-name", r.job, display[1])
		return
	}
	for _, key := range factJobKeys() {
		if strings.HasPrefix(line, "    "+key+":") {
			r.emit("job-has-"+key, r.job, "")
		}
	}
	if uses := factUses.FindStringSubmatch(line); uses != nil {
		r.emit("uses", r.job, uses[1])
	}
}

// readTrigger reads a line of the `on:` block: a reusable workflow declares `workflow_call`, and
// the trap this standard exists to prevent declares `workflow_run`.
func (r *factReader) readTrigger(line string) {
	if factWorkflowCall.MatchString(line) {
		r.emit("reusable", "", "")
	}
	if factWorkflowRun.MatchString(line) {
		r.emit("workflow-run", "", "")
	}
}
