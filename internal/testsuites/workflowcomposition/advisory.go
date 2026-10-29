package main

import (
	"fmt"
	"path/filepath"
	"slices"
	"strings"
)

// Test 16: a check job fails the run when its check fails. A `code-check >` or `security >` job
// carries no job-level `continue-on-error` -- a literal `true`, or an expression that can become
// one -- unless it is listed below with the reason it may stay advisory. The one failure a check
// tolerates is a refused report upload, and that belongs at the upload STEP, so step-level flags
// are outside this rule.
//
// Two lists, because they mean different things:
//
//	ADVISORY    advisory ON PURPOSE, each with the reason recorded where its users read it.
//	UNREVIEWED  advisory since before this rule, with no reason recorded anywhere. Each needs the
//	            check the Go pipeline had before it was made to block -- does any consumer fail it
//	            today? -- because every one that does turns red the moment it blocks. This list may
//	            only SHRINK: a new advisory job goes in ADVISORY with its reason, or is not advisory
//	            at all.
//
// An entry whose job no longer carries the flag fails as well, so neither list outlives the code it
// excuses.

// unreviewedLimit is the ratchet. Lower it when an entry leaves UNREVIEWED; never raise it.
const unreviewedLimit = 30

// The workflows and the job the two lists name more than once.
const (
	npmWorkflow  = "npm.yaml"
	yarnWorkflow = "yarn.yaml"
	hadolintJob  = "security-sast_hadolint"
)

// workflowJob names one job of one workflow.
type workflowJob struct {
	workflow string
	job      string
}

// advisoryReasons is ADVISORY: each job that is advisory by design, with its reason.
func advisoryReasons() map[workflowJob]string {
	eslint := "advisory by design: `style:format` beside it is the blocking formatting gate, and a linter's " +
		"findings need judgement (README, \"JavaScript / TypeScript Tools\")"
	knip := `advisory by design: unused-export detection (README, "JavaScript / TypeScript Tools")`
	return map[workflowJob]string{
		{npmWorkflow, "code_check-style_eslint"}:  eslint,
		{yarnWorkflow, "code_check-style_eslint"}: eslint,
		{npmWorkflow, "code_check-quality_knip"}:  knip,
		{yarnWorkflow, "code_check-quality_knip"}: knip,
		{"dart.yaml", "code_check-quality_unused_code"}: "reachability analysis has a false-positive tail -- " +
			"framework entry points, generated code, `@visibleForTesting` members " +
			"(github/dart/stages/10-code-check/unused/action.yaml)",
	}
}

// unreviewedJobs is UNREVIEWED: the jobs advisory since before the rule, by workflow.
func unreviewedJobs() map[string][]string {
	return map[string][]string{
		"bundler.yaml": {"code_check-style_rubocop", "code_check-quality_debride",
			hadolintJob, "security-sca_bundle_audit"},
		"composer.yaml": {"code_check-style_php_lint", "code_check-quality_phpmd",
			hadolintJob, "security-sca_composer_audit"},
		"dart.yaml":   {hadolintJob, "security-sca_osv_scanner"},
		"dotnet.yaml": {"code_check-quality_resharper", hadolintJob},
		"gradle.yaml": {"code_check-style_checkstyle", "code_check-quality_proguard",
			hadolintJob, "security-sca_dependency_check"},
		"maven.yaml": {"code_check-style_maven_verify", "code_check-quality_proguard",
			hadolintJob, "security-sca_dependency_check"},
		npmWorkflow: {hadolintJob, "security-sca_npm_audit"},
		"pdm.yaml": {"code_check-quality_mypy", "code_check-quality_vulture",
			hadolintJob, "security-sca_safety"},
		"terra.yaml": {"code_check-style_tflint", hadolintJob},
		yarnWorkflow: {hadolintJob, "security-sca_yarn_audit"},
	}
}

// advisoryCanary is a workflow text and the jobs the classifier must flag in it.
type advisoryCanary struct {
	text    string
	flagged []string
}

// advisoryCanaries run the classifier first, so a parser that stops matching fails here instead
// of passing with nothing flagged.
func advisoryCanaries() []advisoryCanary {
	return []advisoryCanary{
		{"jobs:\n  code_check-style_lint:\n    name: 'code-check > style:lint'\n" +
			"    continue-on-error: true\n", []string{"code_check-style_lint"}},
		{"jobs:\n  scan:\n    name: 'security > sca:scan'\n" +
			"    continue-on-error: ${{ inputs.advisory }}\n", []string{scanJob}},
		{"jobs:\n  security-sast_scan:\n    continue-on-error: 'true'\n", []string{"security-sast_scan"}},
		{"jobs:\n  code_check-style_lint:\n    continue-on-error: false\n", []string{}},
		{"jobs:\n  management-report_sonarqube:\n    name: 'management > report:sonarqube'\n" +
			"    continue-on-error: true\n", []string{}},
		{"jobs:\n  security-sast_scan:\n    steps:\n      - uses: 'actions/upload-artifact@v7'\n" +
			"        continue-on-error: true\n", []string{}},
	}
}

func checkAdvisoryJobs(directory string, out *printer) error {
	listed, unreviewed := listedJobs()
	found := map[workflowJob]bool{}
	examined := 0
	for _, name := range globFiles(directory, "*.yaml") {
		examined += advisoryWorkflow(directory, name, listed, found, out)
	}
	for _, entry := range sortedJobs(listed) {
		if !found[entry] {
			out.line(fmt.Sprintf("%s: job %s is listed as advisory but is not -- remove the entry",
				entry.workflow, entry.job))
		}
	}
	if unreviewed > unreviewedLimit {
		out.line(fmt.Sprintf("UNREVIEWED holds %d jobs, more than its limit of %d: it may only shrink, so a new "+
			"advisory job needs an ADVISORY entry with its reason", unreviewed, unreviewedLimit))
	}
	if examined == 0 {
		out.line(fmt.Sprintf("no code-check or security job under %s -- the scan read nothing", directory))
	}
	for _, canary := range advisoryCanaries() {
		flagged, err := canaryFlagged(canary.text)
		if err != nil || !slices.Equal(flagged, canary.flagged) {
			out.line(fmt.Sprintf("the classifier flags %s where it should flag %s in: %s",
				reprStrings(flagged), reprStrings(canary.flagged), reprString(canary.text)))
		}
	}
	return nil
}

// listedJobs is every job ADVISORY or UNREVIEWED excuses, and how many UNREVIEWED holds.
func listedJobs() (map[workflowJob]bool, int) {
	listed := map[workflowJob]bool{}
	for job := range advisoryReasons() {
		listed[job] = true
	}
	unreviewed := 0
	for workflow, workflowJobs := range unreviewedJobs() {
		unreviewed += len(workflowJobs)
		for _, job := range workflowJobs {
			listed[workflowJob{workflow, job}] = true
		}
	}
	return listed, unreviewed
}

// advisoryWorkflow reports the unlisted advisory checks of one workflow, records the advisory ones
// in `found`, and returns how many check jobs it holds.
func advisoryWorkflow(directory, name string, listed, found map[workflowJob]bool, out *printer) int {
	document, err := loadFile(filepath.Join(directory, name), standardYAML)
	if err != nil {
		out.line(fmt.Sprintf("%s: unreadable (%v)", name, err))
		return 0
	}
	checks, advisory, err := advisoryChecks(document)
	for _, job := range advisory {
		found[workflowJob{name, job}] = true
		if !listed[workflowJob{name, job}] {
			out.line(fmt.Sprintf("%s: job %s is advisory -- its job-level `continue-on-error` passes the run "+
				"whatever the check finds. Remove it (a refused upload is tolerated at the upload step), or list "+
				"the job in ADVISORY with the reason it may stay advisory", name, job))
		}
	}
	if err != nil {
		out.line(name + ": " + err.Error())
	}
	return checks
}

// canaryFlagged is what the classifier flags in a canary's workflow text.
func canaryFlagged(text string) ([]string, error) {
	document, err := parseDocument([]byte(text), standardYAML)
	if err != nil {
		return nil, err
	}
	_, flagged, err := advisoryChecks(document)
	return flagged, err
}

// advisoryChecks reads a workflow's jobs and returns how many are checks and which of those are
// advisory, sorted. A job whose body is not a mapping is no check, as it was never a dict.
func advisoryChecks(document *value) (int, []string, error) {
	workflowJobs, err := jobsOf(document)
	if err != nil {
		return 0, nil, err
	}
	checks := 0
	var advisory []string
	for _, job := range workflowJobs.pairs {
		if !job.value.is(mappingKind) || !isCheck(job.key.str(), job.value) {
			continue
		}
		checks++
		if advisoryFlag(job.value.get("continue-on-error"), job.value.has("continue-on-error")) {
			advisory = append(advisory, job.key.str())
		}
	}
	slices.Sort(advisory)
	return checks, advisory, nil
}

// isCheck reports whether a job is a code-check or security job, by its id or its display name.
func isCheck(job string, body *value) bool {
	for _, prefix := range []string{"code_check-", "security-"} {
		if strings.HasPrefix(job, prefix) {
			return true
		}
	}
	name := orText(body.get("name"))
	return strings.HasPrefix(name, "code-check >") || strings.HasPrefix(name, "security >")
}

// advisoryFlag reports whether a `continue-on-error` can let a failure pass: present and anything
// but `false`, the boolean or the string.
func advisoryFlag(flag *value, present bool) bool {
	if !present {
		return false
	}
	return !isFalse(flag)
}

// isFalse is a flag that is `false`: the boolean, or any spelling of the string.
func isFalse(flag *value) bool {
	if flag.is(boolKind) && !flag.boolean {
		return true
	}
	return strings.ToLower(strip(flag.str())) == "false"
}

// sortedJobs is the set's entries ordered by workflow, then job.
func sortedJobs(set map[workflowJob]bool) []workflowJob {
	entries := make([]workflowJob, 0, len(set))
	for entry := range set {
		entries = append(entries, entry)
	}
	slices.SortFunc(entries, func(left, right workflowJob) int {
		if order := strings.Compare(left.workflow, right.workflow); order != 0 {
			return order
		}
		return strings.Compare(left.job, right.job)
	})
	return entries
}
