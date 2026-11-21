package main

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"sort"
	"strconv"
	"strings"

	"github.com/rios0rios0/pipelines/internal/testsuites/filetext"
	"github.com/rios0rios0/pipelines/internal/testsuites/yamldoc"
)

// What the contract is made of, as the workflow spells it.
const (
	baseFile       = "yarn.yaml"
	baseUses       = "rios0rios0/pipelines/.github/workflows/yarn.yaml@main"
	inputName      = "test_shards"
	inputReference = "${{ inputs.test_shards }}"
	shardsJob      = "tests-test_all_shards"
	testAllJob     = "tests-test_all"
	testAllName    = "tests > test:all"
	shardsName     = "tests > test:all (shard ${{ matrix.shard }}/${{ inputs.test_shards }})"
	shardsResult   = "${{ needs.tests-test_all_shards.result }}"
	matrixShard    = "${{ matrix.shard }}"
	installScripts = "${{ inputs.install_run_scripts }}"
	projectScope   = "${{ inputs.working_directory }}"
	coverageDir    = "${{ inputs.working_directory }}/coverage"
	shardsDir      = "${{ env.COVERAGE_DIR }}/shards/"
	readmeHeading  = "(`test_shards`)"
	suiteRow       = "| `yarn-test-shards` |"
)

// The steps the suite names, and the commands that tell the three test steps apart: each is the
// last line of its step's script.
const (
	runShardStep  = "Run the shard"
	stageStep     = "Stage the coverage of the shard"
	uploadStep    = "Upload the coverage of the shard"
	downloadStep  = "Download the coverage of the shards"
	verifyStep    = "Verify the shards"
	mergeStep     = "Merge the coverage of the shards"
	removeStep    = "Remove the coverage of the shards"
	e2eStep       = "Type check the end-to-end specs"
	singleCommand = "yarn test:ci"
	shardCommand  = `yarn test:ci:shard --shard="$SHARD/$TEST_SHARDS"`
	mergeCommand  = "yarn test:ci:merge"
)

// The results GitHub gives the shards job, as `tests > test:all` reads them.
const (
	resultSuccess   = "success"
	resultFailure   = "failure"
	resultCancelled = "cancelled"
	resultSkipped   = "skipped"
)

// The scenario values: a branch and a tag, and the shard counts the scenarios ask for.
const (
	branchRef   = "refs/heads/main"
	tagRef      = "refs/tags/1.2.3"
	oneShard    = 1
	fourShards  = 4
	tooMany     = 17
	minimumEnds = 2 // the table must reach two shards at least, or there is nothing to split
)

// tablePattern is the shard matrix: a JSON table indexed by the input.
var tablePattern = regexp.MustCompile(`^\$\{\{ fromJSON\('([^']*)'\)\[inputs\.test_shards\] \}\}$`)

// setupSteps are what every test job runs before its own steps, and the shards must run them
// exactly as `tests > test:all` does: a copy drifts one input at a time.
func setupSteps() []string {
	return []string{"Checkout code", "Enable Corepack", "Setup Node.js", "Export the build environment"}
}

// reportSteps are the steps that publish what the tests left, in both modes, after the merge.
func reportSteps() []string {
	return []string{"Coverage Report", "Test Results", "Upload Coverage Report"}
}

// readmeTerms are what the README's section must name for a consumer to keep the contract.
func readmeTerms() []string {
	return []string{"test:ci:shard", "test:ci:merge", "--shard=<i>/<n>", "coverage/shards/<i>/", "tests > test:all",
		"re-roots"}
}

type checker struct {
	root     string
	findings []string
}

func (c *checker) emit(group, message string) {
	c.findings = append(c.findings, group+"\t"+message)
}

// check reads the workflows, README.md and AGENTS.md under `root` and writes the findings.
func check(root string, output io.Writer) error {
	c := &checker{root: root}
	base, err := loadWorkflow(root, baseFile)
	if err != nil {
		return err
	}
	jobs := base.Get("jobs")
	c.declares(baseFile, base.Get("on").Get("workflow_call").Get("inputs").Get(inputName))
	if err = c.checkComposed(); err != nil {
		return err
	}
	c.checkNames(jobs)
	limit := c.checkMatrix(jobs.Get(shardsJob))
	c.checkGates(jobs)
	c.checkShardSteps(jobs)
	c.checkTestAllSteps(jobs, limit)
	c.checkHandoff(base, jobs)
	if err = c.checkDocs(base, limit); err != nil {
		return err
	}
	for _, finding := range c.findings {
		if _, err = fmt.Fprintln(output, finding); err != nil {
			return err
		}
	}
	return nil
}

func loadWorkflow(root, name string) (*yamldoc.Node, error) {
	document, err := yamldoc.Load(filepath.Join(root, ".github", "workflows", name), yamldoc.Options{})
	if err != nil {
		return nil, fmt.Errorf("%s: %w", name, err)
	}
	return document, nil
}

// declares holds the input to being OPTIONAL, a number and 1 by default, or every existing
// consumer of the workflow becomes a validation error, or a sharded run, on the next push.
func (c *checker) declares(where string, spec *yamldoc.Node) {
	if spec.Kind() == yamldoc.Null {
		c.emit("input", where+" does not declare `test_shards`")
		return
	}
	if !spec.Get("type").Is("number") {
		c.emit("input", fmt.Sprintf("%s types `test_shards` as %s, not 'number'", where, spec.Get("type").Repr()))
	}
	if !spec.Get("required").IsFalseOrNull() {
		c.emit("input", where+" declares `test_shards` as required")
	}
	if def := spec.Get("default"); def.Kind() != yamldoc.Int || def.Str() != strconv.Itoa(oneShard) {
		c.emit("input", fmt.Sprintf("%s defaults `test_shards` to %s, not 1, so a consumer that passes "+
			"nothing no longer runs the suite in one job", where, def.Repr()))
	}
}

// checkComposed holds every workflow composed on yarn.yaml to declaring the input and handing it
// on: one that drops it accepts the value and runs the suite in one job, which looks exactly like
// the default.
func (c *checker) checkComposed() error {
	paths, err := filepath.Glob(filepath.Join(c.root, ".github", "workflows", "yarn-*.yaml"))
	if err != nil {
		return err
	}
	sort.Strings(paths)
	composed := 0
	for _, path := range paths {
		name := filepath.Base(path)
		document, loadErr := loadWorkflow(c.root, name)
		if loadErr != nil {
			return loadErr
		}
		caller := callerOf(document.Get("jobs"))
		if caller == nil {
			continue
		}
		composed++
		c.declares(name, document.Get("on").Get("workflow_call").Get("inputs").Get(inputName))
		if !caller.Get("with").Get(inputName).Is(inputReference) {
			c.emit("input", name+" does not pass `test_shards` to yarn.yaml, so its consumers' value is dropped "+
				"and the suite runs in one job")
		}
	}
	if composed == 0 {
		c.emit("input", "no .github/workflows/yarn-*.yaml calls yarn.yaml -- the scan read nothing")
	}
	return nil
}

// callerOf is the job that calls yarn.yaml, or nil.
func callerOf(jobs *yamldoc.Node) *yamldoc.Node {
	for _, job := range jobs.Pairs() {
		if job.Value.Get("uses").Is(baseUses) {
			return job.Value
		}
	}
	return nil
}

// needsOf is a job's `needs:`, one id or a list of them.
func needsOf(job *yamldoc.Node) []string {
	needs := job.Get("needs")
	if needs.IsString() {
		return []string{needs.Text()}
	}
	var ids []string
	for _, item := range needs.Items() {
		ids = append(ids, item.Str())
	}
	return ids
}

// checkNames holds ONE job to the name consumers require, in both modes, and the jobs after the
// tests stage to waiting for it.
func (c *checker) checkNames(jobs *yamldoc.Node) {
	var named []string
	for _, job := range jobs.Pairs() {
		if job.Value.Get("name").Is(testAllName) {
			named = append(named, job.Key.Str())
		}
	}
	if !slices.Equal(named, []string{testAllJob}) {
		c.emit("jobs", fmt.Sprintf("the jobs named %s are %v, not %s alone: two check runs of one name, one of "+
			"them skipped, pass a required check whatever the other did", yamldoc.Quote(testAllName), named,
			testAllJob))
	}
	shards := jobs.Get(shardsJob)
	if shards.Kind() == yamldoc.Null {
		c.emit("jobs", "yarn.yaml has no job "+shardsJob)
	} else if !shards.Get("name").Is(shardsName) {
		c.emit("jobs", fmt.Sprintf("%s is named %s, not %s: each shard needs a check of its own, and none may "+
			"be named %s", shardsJob, shards.Get("name").Repr(), yamldoc.Quote(shardsName), yamldoc.Quote(testAllName)))
	}
	if !slices.Contains(needsOf(jobs.Get(testAllJob)), shardsJob) {
		c.emit("jobs", testAllJob+" does not need "+shardsJob+", so it can merge before every shard has finished")
	}
	for _, job := range jobs.Pairs() {
		name := job.Value.Get("name").StrOr("")
		if strings.HasPrefix(name, "management > ") && !slices.Contains(needsOf(job.Value), testAllJob) {
			c.emit("jobs", fmt.Sprintf("%s (%s) no longer needs %s", job.Key.Str(), name, testAllJob))
		}
	}
}

// checkMatrix holds the shard matrix to the numbers 1..n and to reporting every shard, and returns
// how many shards the table reaches (0 when it cannot be read).
func (c *checker) checkMatrix(shards *yamldoc.Node) int {
	strategy := shards.Get("strategy")
	if failFast := strategy.Get("fail-fast"); failFast.Kind() != yamldoc.Bool || failFast.IsTrue() {
		c.emit("matrix", "`fail-fast` is not false, so the first shard to fail cancels the others and their "+
			"failures go unreported until a re-run")
	}
	matrix := strategy.Get("matrix")
	if pairs := matrix.Pairs(); len(pairs) != 1 || !pairs[0].Key.Is("shard") {
		c.emit("matrix", "the matrix holds more than `shard`, so the jobs are not the shards 1..n alone")
	}
	limit, problem := shardTable(matrix.Get("shard").Text())
	if problem != "" {
		c.emit("matrix", problem)
	}
	return limit
}

// shardTable reads the lookup table and returns its last index, or a problem with it.
func shardTable(expression string) (int, string) {
	table := tablePattern.FindStringSubmatch(expression)
	if table == nil {
		return 0, fmt.Sprintf("`shard` is not a table indexed by `inputs.test_shards`: %s", yamldoc.Quote(expression))
	}
	var rows [][]int
	if err := json.Unmarshal([]byte(table[1]), &rows); err != nil {
		return 0, fmt.Sprintf("the shard table is not a JSON list of lists of whole numbers: %v", err)
	}
	for index, row := range rows {
		if !isRange(row, index) {
			return 0, fmt.Sprintf("entry %d of the shard table is %v, not the shards 1 to %d", index, row, index)
		}
	}
	if len(rows) <= minimumEnds {
		return 0, fmt.Sprintf("the shard table ends at %d, before two shards", len(rows)-1)
	}
	return len(rows) - 1, ""
}

// isRange reports whether row is 1..n.
func isRange(row []int, n int) bool {
	if len(row) != n {
		return false
	}
	for index, shard := range row {
		if shard != index+1 {
			return false
		}
	}
	return true
}

// gate is a moment GitHub decides whether one of the two jobs runs, and what it must decide.
type gate struct {
	job       string
	moment    string
	shards    float64
	ref       string
	result    string // the shards' result as `tests > test:all` reads it; "" for the shards job
	failed    bool
	cancelled bool
	runs      bool
}

// gates are the moments that matter: the two modes, a failed shard, a failure further up, a
// cancelled run and a tag. Each row reads: the job, the moment, then what GitHub knows then --
// the shards asked for, the ref, the shards' result, whether a job before failed, whether the run
// was cancelled -- and last whether the job must run.
func gates() []gate {
	return []gate{
		{shardsJob, "one shard is asked for",
			oneShard, branchRef, "", false, false, false},
		{shardsJob, "four shards are asked for",
			fourShards, branchRef, "", false, false, true},
		{shardsJob, "a security job failed",
			fourShards, branchRef, "", true, false, false},
		{shardsJob, "the run was cancelled",
			fourShards, branchRef, "", false, true, false},
		{shardsJob, "the run is a tag's",
			fourShards, tagRef, "", false, false, false},
		{testAllJob, "one shard is asked for",
			oneShard, branchRef, resultSkipped, false, false, true},
		{testAllJob, "one shard is asked for and a security job failed",
			oneShard, branchRef, resultSkipped, true, false, false},
		{testAllJob, "every shard passed",
			fourShards, branchRef, resultSuccess, false, false, true},
		{testAllJob, "a shard failed -- a skipped job would pass a required check",
			fourShards, branchRef, resultFailure, true, false, true},
		{testAllJob, "no shard could start on a test_shards past the table",
			tooMany, branchRef, resultFailure, true, false, true},
		{testAllJob, "a security job failed, so the shards were skipped",
			fourShards, branchRef, resultSkipped, true, false, false},
		{testAllJob, "the run was cancelled",
			fourShards, branchRef, resultCancelled, false, true, false},
		{testAllJob, "the run is a tag's",
			oneShard, tagRef, resultSkipped, false, false, false},
	}
}

// checkGates evaluates each job's `if:` at every moment and reports the moments it gets wrong.
func (c *checker) checkGates(jobs *yamldoc.Node) {
	for _, moment := range gates() {
		properties := map[string]value{
			"inputs.test_shards": numberValue(moment.shards),
			"github.ref":         textValue(moment.ref),
		}
		if moment.result != "" {
			properties["needs."+shardsJob+".result"] = textValue(moment.result)
		}
		context := &scenario{properties: properties, failed: moment.failed, cancelled: moment.cancelled}
		runs, err := holds(jobs.Get(moment.job).Get("if").StrOr(""), context)
		switch {
		case err != nil:
			c.emit("gates", fmt.Sprintf("%s: its `if:` %v", moment.job, err))
		case runs != moment.runs:
			verdict := map[bool]string{true: "runs", false: "is skipped"}[runs]
			c.emit("gates", fmt.Sprintf("%s %s when %s", moment.job, verdict, moment.moment))
		}
	}
}

// stepNamed is the index of the job's step called `name`, or -1.
func stepNamed(steps []*yamldoc.Node, name string) int {
	return slices.IndexFunc(steps, func(step *yamldoc.Node) bool { return step.Get("name").Is(name) })
}

// stepRunning is the index of the step whose script ends in `command`, or -1.
func stepRunning(steps []*yamldoc.Node, command string) int {
	return slices.IndexFunc(steps, func(step *yamldoc.Node) bool { return lastLine(step.Get("run").Text()) == command })
}

// lastLine is the last line of a script, or "" for a step that runs none.
func lastLine(script string) string {
	lines := filetext.Lines(strings.TrimSpace(script))
	if len(lines) == 0 {
		return ""
	}
	return strings.TrimSpace(lines[len(lines)-1])
}

// installPrefix is a test step's script without its last line: the install every test step shares.
func installPrefix(step *yamldoc.Node) string {
	script := strings.TrimSpace(step.Get("run").Text())
	if cut := strings.LastIndex(script, "\n"); cut >= 0 {
		return script[:cut]
	}
	return ""
}

// checkShardSteps holds the shards to the setup `tests > test:all` runs, the install it runs and
// the command that runs one shard.
func (c *checker) checkShardSteps(jobs *yamldoc.Node) {
	shards := jobs.Get(shardsJob).Get("steps").Items()
	testAll := jobs.Get(testAllJob).Get("steps").Items()
	for index, name := range setupSteps() {
		reference := stepNamed(testAll, name)
		if index >= len(shards) || reference < 0 || shards[index].Repr() != testAll[reference].Repr() {
			c.emit("steps", fmt.Sprintf("%s's step %d is not %s exactly as %s runs it", shardsJob, index,
				yamldoc.Quote(name), testAllJob))
		}
	}
	run, stage, upload := stepNamed(shards, runShardStep), stepNamed(shards, stageStep), stepNamed(shards, uploadStep)
	if run < 0 || stage <= run || upload <= stage {
		c.emit("steps", fmt.Sprintf("%s does not run %s, %s and %s in that order", shardsJob,
			yamldoc.Quote(runShardStep), yamldoc.Quote(stageStep), yamldoc.Quote(uploadStep)))
		return
	}
	c.expectEnv(shardsJob, shards[run], map[string]string{
		"SHARD": matrixShard, "TEST_SHARDS": inputReference, "INSTALL_RUN_SCRIPTS": installScripts,
	})
	c.expectEnv(shardsJob, shards[stage], map[string]string{"SHARD": matrixShard})
	if lastLine(shards[run].Get("run").Text()) != shardCommand {
		c.emit("steps", fmt.Sprintf("%s's %s does not end in %s", shardsJob, yamldoc.Quote(runShardStep),
			yamldoc.Quote(shardCommand)))
	}
	for _, step := range []*yamldoc.Node{shards[run], shards[stage]} {
		if !step.Get("working-directory").Is(projectScope) {
			c.emit("steps", fmt.Sprintf("%s's %s runs outside the project", shardsJob, step.Get("name").Repr()))
		}
	}
	single, merge := stepRunning(testAll, singleCommand), stepRunning(testAll, mergeCommand)
	if single >= 0 && merge >= 0 {
		prefix := installPrefix(testAll[single])
		if installPrefix(shards[run]) != prefix || installPrefix(testAll[merge]) != prefix {
			c.emit("steps", "the shards, the merge and the single run do not install the dependencies the same way")
		}
	}
}

// expectEnv reports every entry of `expected` the step's `env:` does not hold as given.
func (c *checker) expectEnv(job string, step *yamldoc.Node, expected map[string]string) {
	keys := make([]string, 0, len(expected))
	for key := range expected {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	for _, key := range keys {
		if !step.Get("env").Get(key).Is(expected[key]) {
			c.emit("steps", fmt.Sprintf("%s's %s does not set %s to %s", job, step.Get("name").Repr(), key,
				yamldoc.Quote(expected[key])))
		}
	}
}

// modeSteps are the steps of `tests > test:all` that belong to one mode, and that mode: true for
// the sharded run.
func modeSteps(steps []*yamldoc.Node) map[int]bool {
	modes := map[int]bool{stepRunning(steps, singleCommand): false}
	for _, name := range []string{downloadStep, verifyStep, mergeStep, removeStep} {
		modes[stepNamed(steps, name)] = true
	}
	return modes
}

// checkTestAllSteps holds each mode of `tests > test:all` to its own steps, in order, with every
// other step running in both.
func (c *checker) checkTestAllSteps(jobs *yamldoc.Node, limit int) {
	steps := jobs.Get(testAllJob).Get("steps").Items()
	modes := modeSteps(steps)
	if _, missing := modes[-1]; missing {
		c.emit("steps", fmt.Sprintf("%s does not hold a step running %s and each of %s, %s, %s and %s",
			testAllJob, yamldoc.Quote(singleCommand), yamldoc.Quote(downloadStep), yamldoc.Quote(verifyStep),
			yamldoc.Quote(mergeStep), yamldoc.Quote(removeStep)))
		return
	}
	for index, step := range steps {
		sharded, only := modes[index]
		for _, mode := range []bool{false, true} {
			runs, err := stepRuns(step, mode)
			want := !only || sharded == mode
			switch {
			case err != nil:
				c.emit("steps", fmt.Sprintf("%s's step %d: its `if:` %v", testAllJob, index, err))
			case runs != want:
				c.emit("steps", fmt.Sprintf("%s's step %d (%s) %s in the %s mode", testAllJob, index,
					step.Get("name").StrOr(lastLine(step.Get("run").Text())),
					map[bool]string{true: "runs", false: "does not run"}[runs], modeName(mode)))
			}
		}
	}
	c.checkOrder(steps)
	verify := steps[stepNamed(steps, verifyStep)]
	c.expectEnv(testAllJob, verify, map[string]string{
		"SHARDS_RESULT": shardsResult, "TEST_SHARDS": inputReference, "TEST_SHARDS_MAX": strconv.Itoa(limit),
	})
	if !verify.Get("working-directory").Is(projectScope) {
		c.emit("steps", fmt.Sprintf("%s's %s reads the shards outside the project", testAllJob,
			yamldoc.Quote(verifyStep)))
	}
}

func modeName(sharded bool) string {
	if sharded {
		return "sharded"
	}
	return "single"
}

// stepRuns reports whether a step runs in one mode on a run where everything before it passed.
func stepRuns(step *yamldoc.Node, sharded bool) (bool, error) {
	shards := float64(oneShard)
	if sharded {
		shards = fourShards
	}
	return holds(step.Get("if").StrOr(""), &scenario{files: true, properties: map[string]value{
		"inputs.test_shards":   numberValue(shards),
		"inputs.e2e_typecheck": booleanValue(true),
		"inputs.build_env":     textValue("API_URL=https://api.invalid"),
	}})
}

// checkOrder holds the sharded steps to the order their files need: the download after the checkout
// that would clean it away, the verdict before the merge, the merge before the clean-up, and every
// report after both modes' tests.
func (c *checker) checkOrder(steps []*yamldoc.Node) {
	checkout := stepNamed(steps, setupSteps()[0])
	download, verify := stepNamed(steps, downloadStep), stepNamed(steps, verifyStep)
	merge, remove := stepNamed(steps, mergeStep), stepNamed(steps, removeStep)
	single := stepRunning(steps, singleCommand)
	sequence := []int{checkout, download, verify, merge, remove}
	if !slices.IsSorted(sequence) || slices.Contains(sequence, -1) {
		c.emit("steps", fmt.Sprintf("%s does not run the checkout, %s, %s, %s and %s in that order",
			testAllJob, yamldoc.Quote(downloadStep), yamldoc.Quote(verifyStep), yamldoc.Quote(mergeStep),
			yamldoc.Quote(removeStep)))
	}
	for _, name := range append([]string{e2eStep}, reportSteps()...) {
		index := stepNamed(steps, name)
		if index < max(single, remove) {
			c.emit("steps", fmt.Sprintf("%s's %s does not come after the tests of both modes", testAllJob,
				yamldoc.Quote(name)))
		}
	}
}

// checkHandoff holds what a shard uploads to what `tests > test:all` downloads: the same directory,
// an artifact name the pattern matches and that differs per shard, and neither step allowed to pass
// when it failed -- the merge cannot judge the coverage without every shard's.
func (c *checker) checkHandoff(base, jobs *yamldoc.Node) {
	if !base.Get("env").Get("COVERAGE_DIR").Is(coverageDir) {
		c.emit("handoff", "the workflow's COVERAGE_DIR is not "+yamldoc.Quote(coverageDir))
	}
	shards := jobs.Get(shardsJob).Get("steps").Items()
	testAll := jobs.Get(testAllJob).Get("steps").Items()
	upload, download := stepAt(shards, stepNamed(shards, uploadStep)), stepAt(testAll, stepNamed(testAll, downloadStep))
	if !strings.HasPrefix(upload.Get("uses").StrOr(""), "actions/upload-artifact@") ||
		!strings.HasPrefix(download.Get("uses").StrOr(""), "actions/download-artifact@") {
		c.emit("handoff", "the shards do not hand their coverage over through actions/upload-artifact and "+
			"actions/download-artifact")
		return
	}
	sent, received := upload.Get("with"), download.Get("with")
	name, pattern := sent.Get("name").Text(), received.Get("pattern").Text()
	prefix, _, perShard := strings.Cut(name, matrixShard)
	if !perShard || pattern != prefix+"*" || received.Has("name") {
		c.emit("handoff", fmt.Sprintf("the artifact %s is not one per shard that the pattern %s downloads every "+
			"one of", yamldoc.Quote(name), yamldoc.Quote(pattern)))
	}
	if !sent.Get("path").Is(shardsDir) || !received.Get("path").Is(shardsDir) {
		c.emit("handoff", fmt.Sprintf("the shards upload %s and the merge downloads %s, not both %s",
			sent.Get("path").Repr(), received.Get("path").Repr(), yamldoc.Quote(shardsDir)))
	}
	if !received.Get("merge-multiple").IsTrue() {
		c.emit("handoff", "the download does not set `merge-multiple`, so each shard lands under its artifact's "+
			"name -- or, with one artifact left, in the directory itself -- and not at coverage/shards/<i>/")
	}
	if !sent.Get("if-no-files-found").Is("error") {
		c.emit("handoff", "a shard that left no coverage uploads nothing and passes")
	}
	for _, step := range []*yamldoc.Node{upload, download} {
		if step.Get("continue-on-error").Truthy() {
			c.emit("handoff", fmt.Sprintf("%s may fail and pass its job, and the merge then judges a suite that "+
				"did not run in full", step.Get("name").Repr()))
		}
	}
}

func stepAt(steps []*yamldoc.Node, index int) *yamldoc.Node {
	if index < 0 {
		return nil
	}
	return steps[index]
}

// checkDocs holds the documentation to the workflow: the input's description and the README's
// section give the same maximum the table ends at, the section states the contract a project keeps,
// and AGENTS.md lists this suite.
func (c *checker) checkDocs(base *yamldoc.Node, limit int) error {
	bound := fmt.Sprintf("from 1 to %d", limit)
	description := base.Get("on").Get("workflow_call").Get("inputs").Get(inputName).Get("description").Text()
	if !strings.Contains(description, bound) {
		c.emit("docs", "the description of `test_shards` does not say "+yamldoc.Quote(bound))
	}
	readme, err := os.ReadFile(filepath.Join(c.root, "README.md"))
	if err != nil {
		return err
	}
	section := readmeSection(string(readme))
	if section == "" {
		c.emit("docs", "README.md has no section headed "+readmeHeading)
	}
	for _, term := range append(readmeTerms(), bound) {
		if section != "" && !strings.Contains(section, term) {
			c.emit("docs", fmt.Sprintf("README.md's %s section does not name %s", readmeHeading, term))
		}
	}
	agents, err := os.ReadFile(filepath.Join(c.root, "AGENTS.md"))
	if err != nil {
		return err
	}
	if !strings.Contains(string(agents), suiteRow) {
		c.emit("docs", "AGENTS.md's suite table has no "+yamldoc.Quote(suiteRow)+" row")
	}
	return nil
}

// readmeSection is the README's section headed `readmeHeading`, up to the next heading of its level
// or above, or "" when there is none.
func readmeSection(readme string) string {
	var section []string
	inside := false
	for _, line := range filetext.Lines(readme) {
		heading := strings.HasPrefix(line, "#### ") || strings.HasPrefix(line, "### ") || strings.HasPrefix(line, "## ")
		if heading && inside {
			break
		}
		if heading && strings.HasPrefix(line, "#### ") && strings.Contains(line, readmeHeading) {
			inside = true
		}
		if inside {
			section = append(section, line)
		}
	}
	return strings.Join(section, "\n")
}

// stepScript is the `run:` of the named step of a job in yarn.yaml, for the suite to execute.
func stepScript(root, job, name string) (string, error) {
	base, err := loadWorkflow(root, baseFile)
	if err != nil {
		return "", err
	}
	steps := base.Get("jobs").Get(job).Get("steps").Items()
	index := stepNamed(steps, name)
	if index < 0 || !steps[index].Get("run").IsString() {
		return "", fmt.Errorf("%s has no step %s that runs a script", job, yamldoc.Quote(name))
	}
	return steps[index].Get("run").Text(), nil
}

// shardLimit is how many shards the table reaches.
func shardLimit(root string) (int, error) {
	base, err := loadWorkflow(root, baseFile)
	if err != nil {
		return 0, err
	}
	limit, problem := shardTable(base.Get("jobs").Get(shardsJob).Get("strategy").Get("matrix").Get("shard").Text())
	if problem != "" {
		return 0, fmt.Errorf("%s", problem)
	}
	return limit, nil
}
