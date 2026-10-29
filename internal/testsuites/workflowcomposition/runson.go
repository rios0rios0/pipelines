package main

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"sort"
	"strings"
)

// Test 10: every workflow declaring `runs_on` declares and consumes it the same way. The suite's
// comment above the assertion carries the reasoning; the shape of each rule is noted where it is
// applied.

const (
	// runsOnDefault is the hosted runner every `runs_on` input defaults to.
	runsOnDefault = `["ubuntu-latest"]`
	// runsOnForward is the `with:` value that hands a caller's `runs_on` to the workflow it calls.
	runsOnForward = "${{ inputs.runs_on }}"
	// thisRepositoryWorkflows prefixes a call to one of this repository's own workflows.
	thisRepositoryWorkflows = "rios0rios0/pipelines/.github/workflows/"
)

var (
	// `${{inputs.runs_on}}` and `${{ inputs.runs_on }}` are the same forward. Comparing the raw
	// string would report the correct one as "not forwarding runs_on", which points a reader at the
	// wrong defect, so every expression is normalised to one space inside its braces first.
	expressionBraces = regexp.MustCompile(`\$\{\{` + space + `*(.*?)` + space + `*\}\}`)
	// A job's runner must be CALLER-SELECTABLE: it resolves from a declared input, or from a
	// fallback chain of them (`inputs.a || inputs.b`). The trailing `\n?` keeps a block scalar's
	// final line break from turning a correct selector into a pinned runner.
	runnerSelector = regexp.MustCompile(
		`^\$\{\{` + space + `*fromJSON\(` + space + `*(inputs\.` + word + `+(?:` + space + `*\|\|` + space +
			`*inputs\.` + word + `+)*)` + space + `*\)` + space + `*\}\}\n?$`)
	chainLink = regexp.MustCompile(`inputs\.(` + word + `+)`)
)

func checkRunsOn(directory string, out *printer) error {
	// The DECLARATION half: these must offer the input at all. A glob matching nothing is itself a
	// finding, so a rename fails rather than passing with nothing left to check.
	mustDeclare := globFiles(directory, "reusable-claude-*.yaml")
	if len(mustDeclare) == 0 {
		out.line("no reusable-claude-*.yaml in .github/workflows/ -- renamed, or removed")
	}
	for _, name := range globFiles(directory, "*.yaml") {
		scan := runsOnScan{directory: directory, name: name, out: out, consumed: map[string]bool{}}
		scan.read(slices.Contains(mustDeclare, name))
		if len(scan.problems) > 0 {
			out.line(name + ": " + strings.Join(scan.problems, "; "))
		}
	}
	return nil
}

// runsOnScan is the CONTRACT half for one workflow.
type runsOnScan struct {
	directory string
	name      string
	out       *printer
	inputs    *value
	problems  []string
	reaches   bool
	consumed  map[string]bool
}

func (s *runsOnScan) problemf(format string, arguments ...any) {
	s.problems = append(s.problems, fmt.Sprintf(format, arguments...))
}

func (s *runsOnScan) read(mustDeclare bool) {
	document, err := loadFile(filepath.Join(s.directory, s.name), standardYAML)
	if err != nil {
		s.problemf("unreadable (%v)", err)
		return
	}
	if err = s.contract(document, mustDeclare); err != nil {
		s.problems = append(s.problems, err.Error())
	}
}

func (s *runsOnScan) contract(document *value, mustDeclare bool) error {
	inputs, err := declaredInputs(document)
	if err != nil {
		return err
	}
	s.inputs = inputs
	spec := inputs.get("runs_on")
	if spec.is(nullKind) {
		return s.undeclared(document, mustDeclare)
	}
	if !spec.is(mappingKind) {
		s.problemf("runs_on is not an input declaration (%s)", spec.repr())
	} else {
		if required := spec.get("required"); !required.is(boolKind) || required.boolean {
			s.problemf("runs_on is not optional")
		}
		if !spec.get("default").isString(runsOnDefault) {
			s.problemf("runs_on does not default to %s", runsOnDefault)
		}
	}
	workflowJobs, err := jobsOf(document)
	if err != nil {
		return err
	}
	for _, job := range workflowJobs.pairs {
		if err = s.job(job); err != nil {
			return err
		}
	}
	// A `<purpose>_runs_on` nothing reads is the same silently ignored input the check below refuses
	// for `runs_on`: the consumer sets it, GitHub accepts it, and the job it names never moves.
	overrides, err := runnerOverrides(document)
	if err != nil {
		return err
	}
	for _, override := range overrides {
		if !s.consumed[override] {
			s.problemf("declares %s that no job resolves from or forwards", override)
		}
	}
	// The runner rule accepts ANY declared input, which is what lets a job with a hard platform
	// requirement take a second one. Without this, a workflow could declare `runs_on` and route
	// every job through something else, so nobody would read the input its consumers set.
	if len(s.problems) == 0 && !s.reaches {
		s.problemf("declares runs_on that no job resolves from or forwards")
	}
	return nil
}

// undeclared handles a workflow that offers no `runs_on`. Its ABSENCE has to be a finding in its
// own right, or the assertion inverts: a workflow that drops the input stops being iterated and
// passes by not being looked at. Two ways it becomes one: a Claude reusable must declare it, and a
// REUSABLE workflow composing one that takes it must pass the choice through. A leaf caller is
// entitled to the default and is not asked.
func (s *runsOnScan) undeclared(document *value, mustDeclare bool) error {
	if mustDeclare {
		s.out.line(s.name + ": declares no runs_on workflow_call input")
		return nil
	}
	reusable, err := triggers(document, "workflow_call")
	if err != nil || !reusable {
		return err
	}
	return eachJob(document, s.composingJob)
}

// composingJob reports a job of a reusable workflow declaring no `runs_on` that calls one taking it.
func (s *runsOnScan) composingJob(job string, body *value) error {
	if !body.has("uses") {
		return nil
	}
	takes, err := takesRunsOn(s.directory, body.get("uses"))
	if takes && err == nil {
		s.out.line(fmt.Sprintf("%s: job %s calls a workflow that takes runs_on, but %s declares no runs_on "+
			"of its own to forward -- its consumers cannot reach another runner", s.name, job, s.name))
	}
	return err
}

func (s *runsOnScan) job(job pair) error {
	body, err := jobBody(job)
	if err != nil {
		return err
	}
	name := job.key.str()
	// A job that CALLS another workflow cannot declare `runs-on` -- GitHub rejects the key there --
	// so it forwards the input instead.
	if body.has("uses") {
		return s.calledJob(name, body)
	}
	selected := normalized(body.get("runs-on"))
	var selector []string
	if selected.is(stringKind) {
		selector = runnerSelector.FindStringSubmatch(selected.text)
	}
	if selector == nil {
		s.problemf("job %s pins a runner instead of resolving one from an input (%s)", name, body.get("runs-on").repr())
		return nil
	}
	var chain []string
	for _, link := range chainLink.FindAllStringSubmatch(selector[1], -1) {
		chain = append(chain, link[1])
	}
	for _, link := range chain {
		if !s.inputs.has(link) {
			s.problemf("job %s resolves its runner from inputs.%s, which the workflow does not declare", name, link)
			return nil
		}
	}
	s.problems = append(s.problems, chainProblems(name, chain, s.inputs)...)
	for _, link := range chain {
		s.consumed[link] = true
	}
	if slices.Contains(chain, "runs_on") {
		s.reaches = true
	}
	return nil
}

func (s *runsOnScan) calledJob(name string, body *value) error {
	takes, err := takesRunsOn(s.directory, body.get("uses"))
	if err != nil || !takes {
		return err
	}
	forwards, err := mappingOr(body.get("with"), "the with: of job "+name)
	if err != nil {
		return err
	}
	if !normalized(forwards.get("runs_on")).isString(runsOnForward) {
		s.problemf("job %s calls a workflow without forwarding runs_on", name)
	} else {
		s.reaches = true
	}
	// The same converse one purpose down: a `<purpose>_runs_on` the callee takes and this workflow
	// does not forward leaves that job on `runs_on` for every consumer of this one, and the fallback
	// makes that look like the default rather than like a drop.
	callee := calleeDocument(s.directory, body.get("uses"))
	if callee == nil {
		return nil
	}
	overrides, err := runnerOverrides(callee)
	if err != nil {
		return err
	}
	for _, override := range overrides {
		switch {
		case !s.inputs.has(override):
			s.problemf("job %s calls a workflow that takes %s, which this workflow does not declare to forward",
				name, override)
		case !normalized(forwards.get(override)).isString("${{ inputs." + override + " }}"):
			s.problemf("job %s calls a workflow without forwarding %s", name, override)
		default:
			s.consumed[override] = true
		}
	}
	return nil
}

// normalized is a string with every `${{ ... }}` respaced to one space inside its braces; any other
// value is itself.
func normalized(v *value) *value {
	if !v.is(stringKind) {
		return v
	}
	return newString(expressionBraces.ReplaceAllString(v.text, "$${{ ${1} }}"))
}

// calleeDocument is the parsed sibling workflow a job CALLS, or nil when it cannot be resolved. By
// base name alone, `someorg/theirrepo/.github/workflows/go.yaml@v1` would resolve to THIS
// repository's `go.yaml` and the forward would be demanded of a callee that does not declare it,
// so only a local path or this repository's own workflows are resolvable.
func calleeDocument(directory string, uses *value) *value {
	reference, _, _ := strings.Cut(uses.str(), "@")
	if !strings.HasPrefix(reference, "./") && !strings.HasPrefix(reference, thisRepositoryWorkflows) {
		return nil
	}
	path := filepath.Join(directory, reference[strings.LastIndex(reference, "/")+1:])
	if info, err := os.Stat(path); err != nil || !info.Mode().IsRegular() {
		return nil
	}
	document, err := loadFile(path, standardYAML)
	if err != nil {
		return nil
	}
	return document
}

// takesRunsOn reports whether the workflow a job CALLS declares a `runs_on` input. A `with:` key
// the callee does not declare is rejected by GitHub outright, so demanding the forward
// unconditionally would be a trap the day a `runs_on`-declaring workflow calls one without it
// (`release.yaml` calls `update-major-version-tag.yaml`). A callee that cannot be resolved is
// assumed to take it, which is the status quo rather than a new silence.
func takesRunsOn(directory string, uses *value) (bool, error) {
	callee := calleeDocument(directory, uses)
	if callee == nil {
		return true, nil
	}
	inputs, err := declaredInputs(callee)
	if err != nil {
		return false, err
	}
	return !inputs.get("runs_on").is(nullKind), nil
}

// runnerOverrides is the `<purpose>_runs_on` inputs a workflow declares beside `runs_on`, sorted.
// One naming rule for every runner-selecting input is what lets a composed workflow be checked
// for dropping one without this file listing which purposes exist.
func runnerOverrides(document *value) ([]string, error) {
	inputs, err := declaredInputs(document)
	if err != nil {
		return nil, err
	}
	var names []string
	for _, entry := range inputs.pairs {
		if entry.key.is(stringKind) && strings.HasSuffix(entry.key.text, "_runs_on") {
			names = append(names, entry.key.text)
		}
	}
	sort.Strings(names)
	return names, nil
}

// chainProblems is how a fallback chain parses correctly and still never reaches part of itself.
// Each link is read only when every link before it is EMPTY. `runs_on` always has a value -- its
// default is the hosted runner -- so any link after it is dead; and a link that is required, or
// defaults to anything but the empty string, is never empty unless a consumer happens to blank it,
// so the links after it are dead by default.
func chainProblems(job string, chain []string, inputs *value) []string {
	var problems []string
	if len(chain) == 0 {
		return nil
	}
	leading := chain[:len(chain)-1]
	if at := slices.Index(leading, "runs_on"); at >= 0 {
		problems = append(problems, fmt.Sprintf(
			"job %s falls back past runs_on, which always has a value, so %s is never read",
			job, strings.Join(chain[at+1:], ", ")))
	}
	for _, name := range leading {
		if name == "runs_on" {
			continue // reported above, and only once
		}
		spec := inputs.get(name)
		required := spec.get("required")
		fallback := spec.get("default")
		if !spec.is(mappingKind) || (required.is(boolKind) && required.boolean) ||
			(!fallback.is(nullKind) && !fallback.isString("")) {
			problems = append(problems, fmt.Sprintf(
				"job %s falls back from inputs.%s, which is not optional with an empty default, so the rest of "+
					"its chain is never reached", job, name))
		}
	}
	return problems
}
