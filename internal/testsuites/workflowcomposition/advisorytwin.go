package main

import (
	"fmt"
	"path"
	"path/filepath"
	"regexp"
	"slices"
	"sort"
	"strings"
)

// Test 16, on the Go pipeline's GitLab CI and Azure DevOps twins, where the flag is spelled
// `allow_failure` and `continueOnError`. Neither platform has a refused upload to excuse -- they
// publish through their own artifact stores -- so a job or a check step carrying the flag fails
// here unless listed. Azure's `task:` steps (a cache, an artifact publish) decide nothing about the
// code and stay outside the rule.
//
// Read from the two Go stage files of each platform AND every stage template they pull in from this
// repository, so a check that moves into a shared template stays covered.

const (
	platformGitLab = "gitlab"
	platformAzure  = "azure"
	// pipelinesRemote prefixes a GitLab include of one of this repository's own templates.
	pipelinesRemote = "https://raw.githubusercontent.com/rios0rios0/pipelines/main/"
	// stepIdentityLength is how much of an unnamed step's script identifies it.
	stepIdentityLength = 60
	// scanJob is the job the canaries flag.
	scanJob = "scan"
)

// azureRunner is the shared script an Azure step runs, which identifies a step with no name.
var azureRunner = regexp.MustCompile(`global/scripts/[` + spaceFreeWord + `./-]+/run\.sh`)

// spaceFreeWord is the body of the `\w` class, for building a larger class around it.
const spaceFreeWord = `\p{L}\p{N}_`

func gitlabStages() []string {
	return []string{"gitlab/golang/stages/10-code-check/go.yaml", "gitlab/golang/stages/20-security/go.yaml"}
}

func azureStages() []string {
	return []string{
		"azure-devops/golang/stages/10-code-check/go.yaml",
		"azure-devops/golang/stages/20-security/go.yaml",
	}
}

// expectedTwinChecks are the Go-specific checks, by the name each platform gives them. Each must be
// found, or a restructure that moved one out of reach would pass by leaving nothing to read.
func expectedTwinChecks() map[string][]string {
	return map[string][]string{
		platformAzure:  {"sca_govulncheck", "style_golangci_lint"},
		platformGitLab: {"sca:govulncheck", "style:golangci-lint"},
	}
}

// twinEntry names a job (GitLab) or a job or step (Azure DevOps) of one file.
type twinEntry struct {
	file  string
	where string
}

// gitlabAdvisory is GITLAB_ADVISORY: GitLab jobs advisory on purpose. There are none.
func gitlabAdvisory() map[twinEntry]string {
	return map[twinEntry]string{}
}

// azureAdvisory is AZURE_ADVISORY. The shared SAST templates are why it is not empty: Azure DevOps
// runs its four SAST tools advisory by the per-platform decision AGENTS.md records, for every
// toolchain at once, and making them block is a decision about every Azure pipeline rather than
// about the Go one.
func azureAdvisory() map[twinEntry]string {
	sharedSAST := "shared by every Azure DevOps pipeline, not just Go: the platform runs its SAST advisory by " +
		"the decision CLAUDE.md records, for every toolchain at once"
	sharedStage := func(tool string) twinEntry {
		return twinEntry{
			file:  "azure-devops/global/stages/20-security/" + tool + ".yaml",
			where: "global/scripts/tools/" + tool + "/run.sh",
		}
	}
	cacheTrim := twinEntry{
		file:  "azure-devops/golang/stages/10-code-check/go.yaml",
		where: "Trim the Go build cache when the agent is low on disk",
	}
	return map[twinEntry]string{
		cacheTrim:               "housekeeping after the lint, not a check: it only frees disk for the cache save",
		sharedStage("semgrep"):  sharedSAST,
		sharedStage("gitleaks"): sharedSAST,
		sharedStage("codeql"):   sharedSAST,
		sharedStage("hadolint"): sharedSAST + ", and consumers of other toolchains carry Hadolint findings today",
	}
}

// gitlabKeywords are the top-level keys of a GitLab file that are not jobs.
func gitlabKeywords() []string {
	return []string{"include", "variables", "stages", "default", "workflow", "image", "services",
		"before_script", "after_script", "cache"}
}

// twinScan collects what the twin check found across both platforms.
type twinScan struct {
	repository string
	problems   []string
	present    map[string]map[string]bool
	used       map[twinEntry]bool
}

func checkAdvisoryTwins(repository string, out *printer) error {
	scan := twinScan{
		repository: repository,
		present:    map[string]map[string]bool{platformGitLab: {}, platformAzure: {}},
		used:       map[twinEntry]bool{},
	}
	if err := scan.read(); err != nil {
		scan.problems = append(scan.problems, err.Error())
	}
	scan.problems = append(scan.problems, scan.missing()...)
	scan.problems = append(scan.problems, scan.stale()...)
	scan.problems = append(scan.problems, twinCanaryProblems()...)
	out.line(strings.Join(scan.problems, "\n"))
	return nil
}

// read scans every file of both platforms, stopping at the first one it cannot read.
func (s *twinScan) read() error {
	files, err := s.gitlabFiles()
	if err != nil {
		return err
	}
	for _, relative := range files {
		if err = s.gitlabFile(relative); err != nil {
			return err
		}
	}
	seen := map[string]bool{}
	for _, stage := range azureStages() {
		seen[stage] = true
		if err = s.azureJobs(stage, seen, s.azureJob); err != nil {
			return err
		}
	}
	return nil
}

// gitlabFile checks the jobs of one GitLab file.
func (s *twinScan) gitlabFile(relative string) error {
	document, err := s.load(relative, gitlabYAML)
	if err != nil {
		return err
	}
	jobs, err := gitlabJobs(document)
	if err != nil {
		return err
	}
	for _, job := range jobs {
		s.present[platformGitLab][job.key.str()] = true
	}
	for _, job := range gitlabFlagged(jobs) {
		entry := twinEntry{relative, job}
		if _, listed := gitlabAdvisory()[entry]; listed {
			s.used[entry] = true
			continue
		}
		s.problems = append(s.problems, fmt.Sprintf("%s: job %s is `allow_failure` -- a failure passes the "+
			"pipeline; remove it, or list it in GITLAB_ADVISORY with its reason", relative, job))
	}
	return nil
}

// load reads one of the repository's pipeline files.
func (s *twinScan) load(relative string, flavor dialect) (*value, error) {
	document, err := loadFile(filepath.Join(s.repository, relative), flavor)
	if err != nil {
		return nil, fmt.Errorf("unreadable (%w)", err)
	}
	return document, nil
}

// gitlabFiles is the Go stage files plus every stage template they include from this repository.
func (s *twinScan) gitlabFiles() ([]string, error) {
	files := gitlabStages()
	for _, stage := range gitlabStages() {
		document, err := s.load(stage, gitlabYAML)
		if err != nil {
			return nil, err
		}
		file, err := root(document)
		if err != nil {
			return nil, err
		}
		for _, entry := range includeEntries(file.get("include")) {
			remote := entry.str()
			if entry.is(mappingKind) {
				remote = ""
				if entry.has("remote") {
					remote = entry.get("remote").str()
				}
			}
			if strings.HasPrefix(remote, pipelinesRemote) && strings.Contains(remote, "/stages/") {
				files = append(files, strings.TrimPrefix(remote, pipelinesRemote))
			}
		}
	}
	return files, nil
}

// includeEntries is a GitLab `include:` as the list of its entries: nothing when it is absent or
// empty, and a lone entry as a list of one.
func includeEntries(includes *value) []*value {
	switch {
	case !includes.truthy():
		return nil
	case includes.is(sequenceKind):
		return includes.items
	default:
		return []*value{includes}
	}
}

// gitlabJobs is a GitLab file's jobs: every top-level mapping that is neither hidden (`.name`) nor
// one of the keywords that configure the pipeline instead.
func gitlabJobs(document *value) ([]pair, error) {
	file, err := mappingOr(document, "the document")
	if err != nil {
		return nil, err
	}
	var jobs []pair
	for _, entry := range file.pairs {
		if !entry.value.is(mappingKind) || strings.HasPrefix(entry.key.str(), ".") {
			continue
		}
		if entry.key.is(stringKind) && slices.Contains(gitlabKeywords(), entry.key.text) {
			continue
		}
		jobs = append(jobs, entry)
	}
	return jobs, nil
}

// gitlabFlagged is the jobs that `allow_failure` -- `true`, or a mapping of exit codes -- sorted.
func gitlabFlagged(jobs []pair) []string {
	var flagged []string
	for _, job := range jobs {
		if flaggedValue(job.value.get("allow_failure")) {
			flagged = append(flagged, job.key.str())
		}
	}
	sort.Strings(flagged)
	return flagged
}

// flaggedValue reports whether a flag is set: present and anything but `false`.
func flaggedValue(flag *value) bool {
	return !flag.is(nullKind) && !isFalse(flag)
}

// azureJobs calls `visit` with every job of a stage file, descending into the job templates it
// names, each template once.
func (s *twinScan) azureJobs(relative string, seen map[string]bool, visit func(relative string, job *value)) error {
	document, err := s.load(relative, standardYAML)
	if err != nil {
		return err
	}
	entries, err := azureEntries(document)
	if err != nil {
		return err
	}
	for _, entry := range entries {
		if !entry.is(mappingKind) {
			continue
		}
		if !entry.has("template") {
			visit(relative, entry)
			continue
		}
		target := templatePath(relative, entry.get("template").str())
		if seen[target] {
			continue
		}
		seen[target] = true
		if err = s.azureJobs(target, seen, visit); err != nil {
			return err
		}
	}
	return nil
}

// azureEntries is every job entry of an Azure file: those of each stage, then its own.
func azureEntries(document *value) ([]*value, error) {
	file, err := root(document)
	if err != nil {
		return nil, err
	}
	stages, err := sequenceOr(file.get("stages"), "stages")
	if err != nil {
		return nil, err
	}
	var entries []*value
	for index, item := range stages.items {
		var stage, stageJobs *value
		if stage, err = mappingOr(item, fmt.Sprintf("stage %d", index+1)); err != nil {
			return nil, err
		}
		if stageJobs, err = sequenceOr(stage.get("jobs"), fmt.Sprintf("`jobs` of stage %d", index+1)); err != nil {
			return nil, err
		}
		entries = append(entries, stageJobs.items...)
	}
	own, err := sequenceOr(file.get("jobs"), "jobs")
	if err != nil {
		return nil, err
	}
	return append(entries, own.items...), nil
}

// templatePath resolves a template reference against the file that names it, the way
// `os.path.normpath(os.path.join(os.path.dirname(relative), template))` does: an absolute
// reference replaces the directory rather than joining it.
func templatePath(relative, template string) string {
	if strings.HasPrefix(template, "/") {
		return path.Clean(template)
	}
	return path.Clean(path.Join(path.Dir(relative), template))
}

// azureJob checks one Azure job and its steps.
func (s *twinScan) azureJob(relative string, job *value) {
	s.present[platformAzure][orText(job.get("job"))] = true
	for _, finding := range azureFlagged(job) {
		where := finding.job
		if finding.isStep {
			where = finding.step
		}
		entry := twinEntry{relative, where}
		if _, listed := azureAdvisory()[entry]; listed {
			s.used[entry] = true
			continue
		}
		location := "job " + finding.job
		if finding.step != "" {
			location = `step "` + finding.step + `" of job ` + finding.job
		}
		s.problems = append(s.problems, fmt.Sprintf("%s: %s is `continueOnError` -- a failure passes the stage; "+
			"remove it, or list it in AZURE_ADVISORY with its reason", relative, location))
	}
}

// azureFinding is a job, or one of its steps, that `continueOnError`. A step is listed by its
// identity, which can be empty for a step with neither a name nor a script.
type azureFinding struct {
	job    string
	step   string
	isStep bool
}

// azureFlagged is every Azure job or check step that `continueOnError`. A `task:` or `template:`
// step decides nothing about the code and is skipped.
func azureFlagged(job *value) []azureFinding {
	name := orText(job.get("job"))
	if name == "" {
		name = orText(job.get("deployment"))
	}
	var found []azureFinding
	if flaggedValue(job.get("continueOnError")) {
		found = append(found, azureFinding{job: name})
	}
	steps := job.get("steps")
	if !steps.is(sequenceKind) {
		return found
	}
	for _, step := range steps.items {
		if !step.is(mappingKind) || step.has("task") || step.has("template") {
			continue
		}
		if flaggedValue(step.get("continueOnError")) {
			found = append(found, azureFinding{job: name, step: stepIdentity(step), isStep: true})
		}
	}
	return found
}

// stepIdentity names a step for a finding: its display name, else the shared runner its script
// calls, else the start of its script.
func stepIdentity(step *value) string {
	if display := step.get("displayName"); display.truthy() {
		return display.str()
	}
	body := ""
	for _, key := range []string{"script", "bash", "pwsh"} {
		if candidate := step.get(key); candidate.truthy() {
			body = candidate.str()
			break
		}
	}
	if runner := azureRunner.FindString(body); runner != "" {
		return runner
	}
	identity := []rune(strip(body))
	if len(identity) > stepIdentityLength {
		identity = identity[:stepIdentityLength]
	}
	return string(identity)
}

// missing is a problem for each expected check the scan never read.
func (s *twinScan) missing() []string {
	var problems []string
	for _, platform := range []string{platformGitLab, platformAzure} {
		for _, name := range expectedTwinChecks()[platform] {
			if !s.present[platform][name] {
				problems = append(problems, fmt.Sprintf("%s: no job %s found in the Go stages or their templates -- "+
					"the scan cannot vouch for a check it never read", platform, name))
			}
		}
	}
	return problems
}

// stale is a problem for each listed exception that no longer excuses anything.
func (s *twinScan) stale() []string {
	var entries []twinEntry
	for entry := range gitlabAdvisory() {
		entries = append(entries, entry)
	}
	for entry := range azureAdvisory() {
		entries = append(entries, entry)
	}
	slices.SortFunc(entries, func(left, right twinEntry) int {
		if order := strings.Compare(left.file, right.file); order != 0 {
			return order
		}
		return strings.Compare(left.where, right.where)
	})
	var problems []string
	for _, entry := range entries {
		if !s.used[entry] {
			problems = append(problems, fmt.Sprintf(`%s: "%s" is listed as advisory but is not -- remove the entry`,
				entry.file, entry.where))
		}
	}
	return problems
}

// gitlabCanary is a GitLab file and the jobs the classifier must flag in it.
type gitlabCanary struct {
	text    string
	flagged []string
}

// azureCanary is a list of Azure jobs and what the classifier must flag in it.
type azureCanary struct {
	text    string
	flagged []azureFinding
}

func gitlabCanaries() []gitlabCanary {
	return []gitlabCanary{
		{"lint:\n  script: [ run ]\n  allow_failure: true\n", []string{"lint"}},
		{"scan:\n  script: [ run ]\n  allow_failure:\n    exit_codes: [ 4 ]\n", []string{"scan"}},
		{"lint:\n  script: [ run ]\n  allow_failure: false\n", nil},
		{".hidden:\n  allow_failure: true\nvariables:\n  A: b\n", nil},
	}
}

func azureCanaries() []azureCanary {
	return []azureCanary{
		{"[{job: scan, continueOnError: true, steps: []}]", []azureFinding{{job: scanJob}}},
		{"[{job: scan, steps: [{script: global/scripts/tools/x/run.sh, continueOnError: 'true'}]}]",
			[]azureFinding{{job: scanJob, step: "global/scripts/tools/x/run.sh", isStep: true}}},
		{"[{job: scan, steps: [{task: PublishPipelineArtifact@1, continueOnError: true}]}]", nil},
		{"[{job: scan, continueOnError: false, steps: [{script: run}]}]", nil},
	}
}

// twinCanaryProblems runs both classifiers against inputs whose verdict is known.
func twinCanaryProblems() []string {
	var problems []string
	for _, canary := range gitlabCanaries() {
		document, err := parseDocument([]byte(canary.text), gitlabYAML)
		var jobs []pair
		if err == nil {
			jobs, err = gitlabJobs(document)
		}
		if err != nil || !slices.Equal(gitlabFlagged(jobs), canary.flagged) {
			problems = append(problems, "the GitLab classifier misreads the canary "+reprString(canary.text))
		}
	}
	for _, canary := range azureCanaries() {
		jobs, err := parseDocument([]byte(canary.text), standardYAML)
		var flagged []azureFinding
		if err == nil {
			for _, job := range jobs.items {
				flagged = append(flagged, azureFlagged(job)...)
			}
		}
		if err != nil || !slices.Equal(flagged, canary.flagged) {
			problems = append(problems, "the Azure DevOps classifier misreads the canary "+jobs.repr())
		}
	}
	return problems
}
