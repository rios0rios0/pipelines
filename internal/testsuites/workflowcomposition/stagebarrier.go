package main

import (
	"fmt"
	"path/filepath"
	"slices"
	"strings"
)

// Test 18: the stages run one after another. A job of the security, tests or management stage needs
// EVERY job of the stage before it, so no job starts beside the stage it follows; a delivery or
// deployment job needs the whole pipeline it ships -- the base workflow it calls, or the last stage
// of its own file. And a job downstream of a check that can be skipped (`basic-checks` runs only on
// a pull request, an opt-in check only when asked for) calls a status function in its own `if:`:
// GitHub skips every job in a dependency chain from a skipped job onwards unless the job's condition
// says otherwise, so the barrier would otherwise stop every later stage on every push. A skip
// further down -- a delivery job that runs only after a release was cut -- may still propagate, on
// purpose.

// The stages a job's display name opens with (`security > sast:codeql`), in the order they run.
const (
	rankCodeCheck = iota + 1
	rankSecurity
	rankTests
	rankManagement
	rankDelivery
	rankDeployment

	lastCheckingStage = rankManagement // the last stage before the pipeline ships
	firstShipping     = rankDelivery
)

// stageRanks maps each stage's name to its place in the run.
func stageRanks() map[string]int {
	return map[string]int{
		"code-check": rankCodeCheck, "security": rankSecurity, "tests": rankTests,
		"management": rankManagement, "delivery": rankDelivery, "deployment": rankDeployment,
	}
}

// stagedJob is what the barrier needs to know about one job.
type stagedJob struct {
	name      string
	rank      int  // 0 for a job outside the stage model
	base      bool // calls a sibling workflow, which runs that workflow's stages, and is named for none
	needs     []string
	skippable bool // carries an `if:`, so it can be skipped
	tolerant  bool // its `if:` calls a status function
}

// barrierCanary is a workflow and the findings the check must report about it.
type barrierCanary struct {
	text     string
	findings int
}

// barrierCanaries run the check first, so a parser that stops reading stages fails here instead of
// passing with nothing flagged.
func barrierCanaries() []barrierCanary {
	head := "jobs:\n" +
		"  a: {name: 'code-check > style:a', if: \"github.event_name == 'pull_request'\"}\n" +
		"  b: {name: 'code-check > style:b'}\n"
	return []barrierCanary{
		// the whole stage, and a skip-tolerant gate: nothing to report
		{head + "  c: {name: 'security > sast:c', needs: [a, b], if: \"!cancelled() && !failure()\"}\n", 0},
		// one code-check job left out of the barrier
		{head + "  c: {name: 'security > sast:c', needs: [b], if: \"!cancelled() && !failure()\"}\n", 1},
		// the whole stage, but the implicit `success()` skips it whenever `a` is skipped
		{head + "  c: {name: 'security > sast:c', needs: [a, b]}\n", 1},
		// a delivery job that does not wait for the pipeline it ships
		{"jobs:\n  go: {uses: 'rios0rios0/pipelines/.github/workflows/go.yaml@main'}\n" +
			"  d: {name: 'delivery > release'}\n", 1},
		// a delivery job that skips when the release it follows was not cut, on purpose
		{"jobs:\n  go: {uses: 'rios0rios0/pipelines/.github/workflows/go.yaml@main'}\n" +
			"  d: {name: 'delivery > release', needs: go, if: \"github.event_name == 'push'\"}\n" +
			"  e: {name: 'delivery > tag', needs: [go, d], uses: './.github/workflows/tag.yaml'}\n", 0},
	}
}

func checkStageBarrier(directory string, out *printer) error {
	var problems []string
	for index, canary := range barrierCanaries() {
		document, err := parseDocument([]byte(canary.text), standardYAML)
		if err != nil {
			problems = append(problems, fmt.Sprintf("canary %d does not parse: %v", index+1, err))
			continue
		}
		found, _, err := barrierFindings(fmt.Sprintf("canary %d", index+1), document)
		if err != nil || len(found) != canary.findings {
			problems = append(problems, fmt.Sprintf("the barrier check reports %d finding(s) about canary %d, not %d",
				len(found), index+1, canary.findings))
		}
	}
	staged := 0
	for _, name := range globFiles(directory, "*.yaml") {
		document, err := loadFile(filepath.Join(directory, name), standardYAML)
		if err != nil {
			problems = append(problems, fmt.Sprintf("%s: unreadable (%v)", name, err))
			continue
		}
		found, counted, err := barrierFindings(name, document)
		problems = append(problems, found...)
		staged += counted
		if err != nil {
			problems = append(problems, name+": "+err.Error())
		}
	}
	if staged == 0 {
		problems = append(problems,
			fmt.Sprintf("no job under %s is named for a stage -- the scan read nothing", directory))
	}
	out.line(strings.Join(problems, "\n"))
	return nil
}

// barrierFindings is every barrier and skip finding about one workflow, and how many of its jobs are
// named for a stage.
func barrierFindings(name string, document *value) ([]string, int, error) {
	jobs, order, err := stagedJobs(document)
	if err != nil {
		return nil, 0, err
	}
	var problems []string
	staged := 0
	for _, id := range order {
		if jobs[id].rank > 0 {
			staged++
		}
		upstream := closure(id, jobs)
		problems = append(problems, barrierGaps(name, id, jobs, order, upstream)...)
		if skipped := skippedCheck(jobs[id], jobs, order, upstream); skipped != "" {
			problems = append(problems, fmt.Sprintf("%s: job %s needs %s, which can be skipped, and its `if:` "+
				"calls no status function, so GitHub skips it too whenever %s is skipped -- gate it on "+
				"`!cancelled() && !failure() && (...)`", name, id, skipped, skipped))
		}
	}
	return problems, staged, nil
}

// barrierGaps is a finding for every job `id` must wait for and can start before.
func barrierGaps(name, id string, jobs map[string]stagedJob, order []string, upstream map[string]bool) []string {
	var problems []string
	job := jobs[id]
	for _, waited := range barrierFor(job, jobs, order) {
		if waited != id && !upstream[waited] {
			problems = append(problems, fmt.Sprintf("%s: job %s (%s) can start before %s (%s) finishes -- add it "+
				"to `needs:`, so each stage waits for the whole stage before it", name, id, job.name, waited,
				jobs[waited].name))
		}
	}
	return problems
}

// skippedCheck is the first check upstream of `job` that can be skipped while `job` keeps the implicit
// `success()`, or "" when there is none or the job's condition already calls a status function.
func skippedCheck(job stagedJob, jobs map[string]stagedJob, order []string, upstream map[string]bool) string {
	if job.tolerant {
		return ""
	}
	for _, ancestor := range order {
		check := jobs[ancestor]
		if upstream[ancestor] && check.skippable && check.rank >= rankCodeCheck && check.rank <= lastCheckingStage {
			return ancestor
		}
	}
	return ""
}

// barrierFor is the jobs `job` must wait for: every job of the nearest earlier checking stage in the
// file, and for a delivery or deployment job also every base workflow the file calls.
func barrierFor(job stagedJob, jobs map[string]stagedJob, order []string) []string {
	if job.rank < rankSecurity {
		return nil
	}
	limit := job.rank - 1
	if job.rank >= firstShipping {
		limit = lastCheckingStage
	}
	previous := 0
	for _, id := range order {
		if rank := jobs[id].rank; rank <= limit && rank > previous {
			previous = rank
		}
	}
	var waited []string
	for _, id := range order {
		other := jobs[id]
		if (previous > 0 && other.rank == previous) || (job.rank >= firstShipping && other.base) {
			waited = append(waited, id)
		}
	}
	return waited
}

// stagedJobs reads every job of a workflow, and their ids in document order.
func stagedJobs(document *value) (map[string]stagedJob, []string, error) {
	jobs := map[string]stagedJob{}
	var order []string
	err := eachJob(document, func(id string, body *value) error {
		job := stagedJob{}
		if title := body.get("name"); title.is(stringKind) {
			job.name = title.text
			if stage, _, found := strings.Cut(title.text, " > "); found {
				job.rank = stageRanks()[strings.TrimSpace(stage)]
			}
		}
		if uses := body.get("uses"); uses.is(stringKind) {
			job.base = job.rank == 0 && (strings.HasPrefix(uses.text, "rios0rios0/pipelines/.github/workflows/") ||
				strings.HasPrefix(uses.text, "./.github/workflows/"))
		}
		needs, err := jobNeeds(body)
		if err != nil {
			return fmt.Errorf("job %s: %w", id, err)
		}
		job.needs = needs
		if condition := body.get("if"); !condition.is(nullKind) {
			job.skippable = true
			job.tolerant = callsStatus(quotedString.ReplaceAllLiteralString(condition.str(), "''"))
		}
		jobs[id] = job
		order = append(order, id)
		return nil
	})
	return jobs, order, err
}

// jobNeeds is a job's `needs:`, which GitHub accepts as one job id or a list of them.
func jobNeeds(body *value) ([]string, error) {
	needs := body.get("needs")
	switch {
	case needs.is(nullKind):
		return nil, nil
	case needs.is(stringKind):
		return []string{needs.text}, nil
	}
	list, err := sequenceOr(needs, "needs")
	if err != nil {
		return nil, err
	}
	var ids []string
	for _, item := range list.items {
		ids = append(ids, item.str())
	}
	return ids, nil
}

// closure is the set of jobs `id` waits for, directly or through another job.
func closure(id string, jobs map[string]stagedJob) map[string]bool {
	seen := map[string]bool{}
	pending := slices.Clone(jobs[id].needs)
	for len(pending) > 0 {
		next := pending[len(pending)-1]
		pending = pending[:len(pending)-1]
		if seen[next] {
			continue
		}
		seen[next] = true
		pending = append(pending, jobs[next].needs...)
	}
	return seen
}
