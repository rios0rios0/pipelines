package main

import (
	"fmt"
	"slices"
	"sort"
	"strconv"
	"strings"

	"github.com/rios0rios0/pipelines/internal/testsuites/filetext"
	"github.com/rios0rios0/pipelines/internal/testsuites/yamldoc"
)

// checkDefault holds the default `tests > test:all` to the job it was before test sharding existed:
// every key and value the fixture holds, in order, and the fixture's `if:` with `defaultGuard`
// appended. Sharding is opt-in, and the default job is what every Yarn consumer runs, all at once.
func (c *checker) checkDefault(job, fixture *yamldoc.Node) {
	if fixture.Kind() != yamldoc.Mapping {
		c.emit("default", fixturePath()+" holds no "+testAllJob+" job")
		return
	}
	keys := map[string]bool{}
	for _, document := range []*yamldoc.Node{fixture, job} {
		for _, pair := range document.Pairs() {
			keys[pair.Key.Str()] = true
		}
	}
	names := make([]string, 0, len(keys))
	for key := range keys {
		names = append(names, key)
	}
	sort.Strings(names)
	for _, key := range names {
		expected := fixture.Get(key).Repr()
		if key == "if" {
			expected = yamldoc.Quote(fixture.Get(key).Text() + defaultGuard)
		}
		if got := job.Get(key).Repr(); got != expected {
			c.emit("default", fmt.Sprintf("%s's `%s` is not the default job's (%s): it is %s, not %s", testAllJob,
				key, fixturePath(), clip(got), clip(expected)))
		}
	}
}

// clip is a value short enough to read in a finding.
func clip(text string) string {
	const longest = 160
	if len(text) <= longest {
		return text
	}
	return text[:longest] + "..."
}

// The moments every job is asked about.
const (
	momentOneShard  = "one shard is asked for"
	momentCancelled = "the run was cancelled"
	momentTag       = "the run is a tag's"
)

// gate is a moment GitHub decides whether one of the three jobs runs, and what it must decide.
type gate struct {
	job       string
	moment    string
	shards    float64
	ref       string
	result    string // the shards' result as the merged job reads it; "" for the jobs that do not
	failed    bool
	cancelled bool
	runs      bool
}

// gates are the moments that matter: both modes, a failed shard, a value past the table, a failure
// further up, a cancelled run and a tag. Each row reads: the job, the moment, then what GitHub knows
// then -- the shards asked for, the ref, the shards' result, whether a job before failed, whether
// the run was cancelled -- and last whether the job must run.
func gates() []gate {
	return []gate{
		{shardsJob, momentOneShard, oneShard, branchRef, "", false, false, false},
		{shardsJob, "four shards are asked for", fourShards, branchRef, "", false, false, true},
		{shardsJob, "a security job failed", fourShards, branchRef, "", true, false, false},
		{shardsJob, momentCancelled, fourShards, branchRef, "", false, true, false},
		{shardsJob, momentTag, fourShards, tagRef, "", false, false, false},
		{testAllJob, momentOneShard, oneShard, branchRef, "", false, false, true},
		{testAllJob, "four shards are asked for", fourShards, branchRef, "", false, false, false},
		{testAllJob, "a security job failed", oneShard, branchRef, "", true, false, false},
		{testAllJob, momentCancelled, oneShard, branchRef, "", false, true, false},
		{testAllJob, momentTag, oneShard, tagRef, "", false, false, false},
		{mergedJob, momentOneShard,
			oneShard, branchRef, resultSkipped, false, false, false},
		{mergedJob, "every shard passed",
			fourShards, branchRef, resultSuccess, false, false, true},
		{mergedJob, "a shard failed -- a skipped job would pass a required check",
			fourShards, branchRef, resultFailure, true, false, true},
		{mergedJob, "no shard could start on a test_shards past the table",
			tooMany, branchRef, resultFailure, true, false, true},
		{mergedJob, "a security job failed, so the shards were skipped",
			fourShards, branchRef, resultSkipped, true, false, false},
		{mergedJob, momentCancelled,
			fourShards, branchRef, resultCancelled, false, true, false},
		{mergedJob, momentTag,
			fourShards, tagRef, resultSkipped, false, false, false},
	}
}

// checkGates evaluates each job's `if:` at every moment and reports the moments it gets wrong. Only
// the merged job is handed the shards' result: the others do not need the shards, so a condition of
// theirs that read it is reported as reading what no scenario models.
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

// stepAt is the step at `index`, or nil for -1.
func stepAt(steps []*yamldoc.Node, index int) *yamldoc.Node {
	if index < 0 {
		return nil
	}
	return steps[index]
}

// checkCopies reports every step `names` lists that `job` does not run exactly as the default job
// runs it, and returns where each sits in `job` (-1 when it does not).
func (c *checker) checkCopies(job string, steps, reference []*yamldoc.Node, names []string) []int {
	positions := make([]int, 0, len(names))
	for _, name := range names {
		index, original := stepNamed(steps, name), stepAt(reference, stepNamed(reference, name))
		if original == nil || index < 0 || steps[index].Repr() != original.Repr() {
			c.emit("steps", fmt.Sprintf("%s does not run %s exactly as %s runs it", job, yamldoc.Quote(name),
				testAllJob))
		}
		positions = append(positions, index)
	}
	return positions
}

// checkShardSteps holds the shards to the setup `tests > test:all` runs, first, the install it runs
// and the command that runs one shard.
func (c *checker) checkShardSteps(jobs *yamldoc.Node) {
	shards := jobs.Get(shardsJob).Get("steps").Items()
	reference := jobs.Get(testAllJob).Get("steps").Items()
	if positions := c.checkCopies(shardsJob, shards, reference, setupSteps()); !slices.Equal(positions,
		[]int{0, 1, 2, 3}) {
		c.emit("steps", shardsJob+" does not start with the setup steps, in their order")
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
	c.checkInstall(shardsJob, shards[run], stepAt(reference, stepRunning(reference, singleCommand)))
}

// checkInstall holds a step to installing the dependencies as the default job's test step does.
func (c *checker) checkInstall(job string, step, reference *yamldoc.Node) {
	if reference == nil || installPrefix(step) != installPrefix(reference) {
		c.emit("steps", fmt.Sprintf("%s's %s does not install the dependencies as %s does", job,
			step.Get("name").Repr(), testAllJob))
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

// checkMergedSteps holds the merged job to the default job's setup and report steps, its own steps
// in the order their files need -- the download after the checkout that would clean it away, the
// verdict before the install and the merge, the clean-up after the merge and before the reports --
// and every step to running on a sharded run that passed.
func (c *checker) checkMergedSteps(jobs *yamldoc.Node, limit int) {
	steps := jobs.Get(mergedJob).Get("steps").Items()
	reference := jobs.Get(testAllJob).Get("steps").Items()
	setup := c.checkCopies(mergedJob, steps, reference, setupSteps())
	reports := c.checkCopies(mergedJob, steps, reference, append([]string{e2eStep}, reportSteps()...))
	download, verify := stepNamed(steps, downloadStep), stepNamed(steps, verifyStep)
	merge, remove := stepNamed(steps, mergeStep), stepNamed(steps, removeStep)
	order := append([]int{setup[0], download, verify}, setup[1:]...)
	order = append(append(order, merge, remove), reports...)
	if slices.Contains(order, -1) || !slices.IsSorted(order) {
		c.emit("steps", fmt.Sprintf("%s does not run the checkout, %s, %s, the rest of the setup, %s, %s and the "+
			"reports in that order", mergedJob, yamldoc.Quote(downloadStep), yamldoc.Quote(verifyStep),
			yamldoc.Quote(mergeStep), yamldoc.Quote(removeStep)))
		return
	}
	if lastLine(steps[merge].Get("run").Text()) != mergeCommand {
		c.emit("steps", fmt.Sprintf("%s's %s does not end in %s", mergedJob, yamldoc.Quote(mergeStep),
			yamldoc.Quote(mergeCommand)))
	}
	c.checkInstall(mergedJob, steps[merge], stepAt(reference, stepRunning(reference, singleCommand)))
	c.expectEnv(mergedJob, steps[verify], map[string]string{
		"SHARDS_RESULT": shardsResult, "TEST_SHARDS": inputReference, "TEST_SHARDS_MAX": strconv.Itoa(limit),
	})
	for _, index := range []int{verify, merge, remove} {
		if !steps[index].Get("working-directory").Is(projectScope) {
			c.emit("steps", fmt.Sprintf("%s's %s runs outside the project", mergedJob, steps[index].Get("name").Repr()))
		}
	}
	c.checkMergedRuns(steps, remove)
}

// checkMergedRuns holds every step of the merged job to running on a sharded run that passed, and
// the clean-up to running after a failed step too, so a merge that failed on the threshold leaves
// no shard in the coverage artifact.
func (c *checker) checkMergedRuns(steps []*yamldoc.Node, remove int) {
	for index, step := range steps {
		runs, err := stepRuns(step, false)
		switch {
		case err != nil:
			c.emit("steps", fmt.Sprintf("%s's step %d: its `if:` %v", mergedJob, index, err))
		case !runs:
			c.emit("steps", fmt.Sprintf("%s's step %d (%s) does not run on a sharded run that passed", mergedJob,
				index, step.Get("name").StrOr(lastLine(step.Get("run").Text()))))
		}
	}
	if runs, err := stepRuns(steps[remove], true); err != nil || !runs {
		c.emit("steps", fmt.Sprintf("%s's %s does not run after a failed step, so a failed merge leaves the "+
			"shards in the coverage artifact", mergedJob, yamldoc.Quote(removeStep)))
	}
}

// stepRuns reports whether a step of the merged job runs on a sharded run, after a failed step or
// not.
func stepRuns(step *yamldoc.Node, failed bool) (bool, error) {
	return holds(step.Get("if").StrOr(""), &scenario{files: true, failed: failed, properties: map[string]value{
		"inputs.test_shards":   numberValue(fourShards),
		"inputs.e2e_typecheck": booleanValue(true),
		"inputs.build_env":     textValue("API_URL=https://api.invalid"),
	}})
}

// checkHandoff holds what a shard uploads to what the merged job downloads: the same directory, an
// artifact name the pattern matches and that differs per shard, and neither step allowed to pass
// when it failed -- the merge cannot judge the coverage without every shard's.
func (c *checker) checkHandoff(base, jobs *yamldoc.Node) {
	if !base.Get("env").Get("COVERAGE_DIR").Is(coverageDir) {
		c.emit("handoff", "the workflow's COVERAGE_DIR is not "+yamldoc.Quote(coverageDir))
	}
	shards := jobs.Get(shardsJob).Get("steps").Items()
	merged := jobs.Get(mergedJob).Get("steps").Items()
	upload, download := stepAt(shards, stepNamed(shards, uploadStep)), stepAt(merged, stepNamed(merged, downloadStep))
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
