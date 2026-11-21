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
	testAllJob     = "tests-test_all"
	testAllName    = "tests > test:all"
	shardsJob      = "tests-test_all_shards"
	shardsName     = "tests > test:all (shard ${{ matrix.shard }}/${{ inputs.test_shards }})"
	mergedJob      = "tests-test_all_merged"
	mergedName     = "tests > test:all (merged)"
	defaultGuard   = " && inputs.test_shards <= 1"
	shardsResult   = "${{ needs.tests-test_all_shards.result }}"
	matrixShard    = "${{ matrix.shard }}"
	installScripts = "${{ inputs.install_run_scripts }}"
	projectScope   = "${{ inputs.working_directory }}"
	coverageDir    = "${{ inputs.working_directory }}/coverage"
	shardsDir      = "${{ env.COVERAGE_DIR }}/shards/"
	readmeHeading  = "(`test_shards`)"
	suiteRow       = "| `yarn-test-shards` |"
)

// fixturePath is the default `tests > test:all` job as it was before test sharding existed, which
// the default job must stay but for its `if:`.
func fixturePath() string {
	return filepath.Join(".github", "tests", "fixtures", "yarn-test-all.yaml")
}

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

// The results GitHub gives the shards job, as the merged job reads them.
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

// setupSteps are what every test job runs before its own steps, and the shards and the merge must
// run them exactly as `tests > test:all` does: a copy drifts one input at a time.
func setupSteps() []string {
	return []string{"Checkout code", "Enable Corepack", "Setup Node.js", "Export the build environment"}
}

// reportSteps are the steps that publish what the tests left, which the merge runs as
// `tests > test:all` does.
func reportSteps() []string {
	return []string{"Coverage Report", "Test Results", "Upload Coverage Report"}
}

// readmeTerms are what the README's section must name for a consumer to keep the contract.
func readmeTerms() []string {
	return []string{"test:ci:shard", "test:ci:merge", "--shard=<i>/<n>", "coverage/shards/<i>/", "re-roots",
		mergedName, "deployment_required_checks", "SonarQube"}
}

type checker struct {
	root     string
	findings []string
}

func (c *checker) emit(group, message string) {
	c.findings = append(c.findings, group+"\t"+message)
}

// check reads the workflows, the fixture, README.md and AGENTS.md under `root` and writes the
// findings.
func check(root string, output io.Writer) error {
	c := &checker{root: root}
	base, err := loadWorkflow(root, baseFile)
	if err != nil {
		return err
	}
	fixture, err := yamldoc.Load(filepath.Join(root, fixturePath()), yamldoc.Options{})
	if err != nil {
		return fmt.Errorf("%s: %w", fixturePath(), err)
	}
	jobs := base.Get("jobs")
	c.declares(baseFile, base.Get("on").Get("workflow_call").Get("inputs").Get(inputName))
	if err = c.checkComposed(); err != nil {
		return err
	}
	c.checkDefault(jobs.Get(testAllJob), fixture.Get("jobs").Get(testAllJob))
	c.checkNames(jobs)
	limit := c.checkMatrix(jobs.Get(shardsJob))
	c.checkGates(jobs)
	c.checkShardSteps(jobs)
	c.checkMergedSteps(jobs, limit)
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

// jobsNamed is the ids of the jobs called `name`.
func jobsNamed(jobs *yamldoc.Node, name string) []string {
	var named []string
	for _, job := range jobs.Pairs() {
		if job.Value.Get("name").Is(name) {
			named = append(named, job.Key.Str())
		}
	}
	return named
}

// checkNames holds each check name to one job: `tests > test:all` to the default job and
// `tests > test:all (merged)` to the merge. Were they one name, every run would carry two check runs
// of it, one of them skipped -- in the default mode too -- and a skipped run satisfies a required
// check whatever the other did. It holds the merge to waiting for every shard and every security
// job, and the jobs after the tests stage to the default job they always needed.
func (c *checker) checkNames(jobs *yamldoc.Node) {
	for _, pair := range [][2]string{{testAllName, testAllJob}, {mergedName, mergedJob}} {
		name, job := pair[0], pair[1]
		if named := jobsNamed(jobs, name); !slices.Equal(named, []string{job}) {
			c.emit("jobs", fmt.Sprintf("the jobs named %s are %v, not %s alone: two check runs of one name, one "+
				"of them skipped, pass a required check whatever the other did", yamldoc.Quote(name), named, job))
		}
	}
	if !jobs.Get(shardsJob).Get("name").Is(shardsName) {
		c.emit("jobs", fmt.Sprintf("%s is named %s, not %s: each shard needs a check of its own", shardsJob,
			jobs.Get(shardsJob).Get("name").Repr(), yamldoc.Quote(shardsName)))
	}
	merged := needsOf(jobs.Get(mergedJob))
	for _, job := range jobs.Pairs() {
		id, name := job.Key.Str(), job.Value.Get("name").StrOr("")
		waits := id == shardsJob || strings.HasPrefix(name, "security > ")
		if waits && !slices.Contains(merged, id) {
			c.emit("jobs", fmt.Sprintf("%s does not need %s, so it can merge before %s has finished", mergedJob,
				id, id))
		}
		if strings.HasPrefix(name, "management > ") && !slices.Contains(needsOf(job.Value), testAllJob) {
			c.emit("jobs", fmt.Sprintf("%s (%s) no longer needs %s", id, name, testAllJob))
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

// checkDocs holds the documentation to the workflow: the input's description and the README's
// section give the same maximum the table ends at, both name the check an opting-in consumer must
// require instead, the section states the contract a project keeps, and AGENTS.md lists this suite.
func (c *checker) checkDocs(base *yamldoc.Node, limit int) error {
	bound := fmt.Sprintf("from 1 to %d", limit)
	description := base.Get("on").Get("workflow_call").Get("inputs").Get(inputName).Get("description").Text()
	for _, term := range []string{bound, mergedName} {
		if !strings.Contains(description, term) {
			c.emit("docs", "the description of `test_shards` does not say "+yamldoc.Quote(term))
		}
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
