package main

import (
	"fmt"
	"path/filepath"
	"strings"
)

// Test 14: the review job skips the pull requests automation opens. The guard is EVALUATED, not
// matched -- run against ten pull requests whose verdict is known -- which is what makes the
// assertion survive a reordering, a rename of the input, or a rewrite from `startsWith` to
// `contains`, while still failing when a prefix is dropped.

const (
	reviewWorkflow   = "reusable-claude-review.yaml"
	reviewJob        = "claude-review"
	reviewRepository = "rios0rios0/pipelines"
	reviewPrefix     = "autoupdate_branch_prefix"
	featureBranch    = "feat/x"
)

// reviewCase is one pull request and whether the review must run on it.
type reviewCase struct {
	label string
	ref   string
	fork  bool
	draft bool
	// prefix overrides the input's declared default when set: the empty-prefix trap.
	prefix   *string
	reviewed bool
}

// reviewCases are the ten pull requests. Two are the traps: a plain feature branch must still BE
// reviewed (or "skip everything" passes), and emptying the input must give up only the autoupdate
// exemption -- `startsWith` with an empty prefix is TRUE, so an input used without a non-empty check silently
// disables every review in the repository that set it.
func reviewCases() []reviewCase {
	off := ""
	return []reviewCase{
		{label: "a feature branch", ref: "feat/add-logs", reviewed: true},
		{label: "a fix branch", ref: "fix/TICKET-990", reviewed: true},
		{label: "an autobump release", ref: "chore/bump-5.1.0"},
		{label: "a manual release", ref: "bump/5.1.0"},
		{label: "an autoupdate run", ref: "chore/autoupdate-2026-08-28"},
		{label: "a dependabot bump", ref: "dependabot/github_actions/x"},
		{label: "a fork", ref: featureBranch, fork: true},
		{label: "a draft", ref: featureBranch, draft: true},
		{label: "a feature branch, prefix off", ref: featureBranch, prefix: &off, reviewed: true},
		{label: "an autobump release, prefix off", ref: "chore/bump-5.1.0", prefix: &off},
	}
}

func checkReviewGuard(directory string, out *printer) error {
	document, err := loadFile(filepath.Join(directory, reviewWorkflow), standardYAML)
	if err != nil {
		out.line(fmt.Sprintf("%s: unreadable (%v)", reviewWorkflow, err))
		return nil
	}
	if err = reviewGuard(document, out); err != nil {
		out.line(reviewWorkflow + ": " + err.Error())
	}
	return nil
}

func reviewGuard(document *value, out *printer) error {
	inputs, err := declaredInputs(document)
	if err != nil {
		return err
	}
	declared, err := mappingOr(inputs.get(reviewPrefix), "the "+reviewPrefix+" input")
	if err != nil {
		return err
	}
	defaultPrefix := ""
	if declared.has("default") {
		defaultPrefix = declared.get("default").str()
	}
	workflowJobs, err := jobsOf(document)
	if err != nil {
		return err
	}
	body, err := mappingOr(workflowJobs.get(reviewJob), "job "+reviewJob)
	if err != nil {
		return err
	}
	condition := ""
	if body.has("if") {
		condition = collapse(body.get("if").str())
	}
	if condition == "" {
		out.line(fmt.Sprintf("%s: job %s has no `if:` -- every automation pull request is reviewed",
			reviewWorkflow, reviewJob))
		return nil
	}
	for _, pullRequest := range reviewCases() {
		prefix := defaultPrefix
		if pullRequest.prefix != nil {
			prefix = *pullRequest.prefix
		}
		reviewed, evaluation := evaluateCondition(condition, pullRequest.properties(prefix))
		if evaluation != nil {
			out.line(fmt.Sprintf("%s: %s (%s) could not be evaluated: %v",
				reviewWorkflow, pullRequest.label, pullRequest.ref, evaluation))
			continue
		}
		if reviewed == pullRequest.reviewed {
			continue
		}
		verb, want := "is not reviewed", "must not be"
		if reviewed {
			verb = "is reviewed"
		}
		if pullRequest.reviewed {
			want = "must be"
		}
		out.line(
			fmt.Sprintf("%s: %s (%s) %s, but it %s", reviewWorkflow, pullRequest.label, pullRequest.ref, verb, want),
		)
	}
	return nil
}

// properties are the context values the guard may read for this pull request. GitHub matches
// property names ignoring case, so the lookup does too; a property outside this table fails the
// evaluation rather than reading as empty.
func (c reviewCase) properties(prefix string) lookup {
	headRepository := reviewRepository
	if c.fork {
		headRepository = "someone/fork"
	}
	known := map[string]exprValue{
		"github.repository":                             exprText(reviewRepository),
		"github.event.pull_request.head.repo.full_name": exprText(headRepository),
		"github.event.pull_request.draft":               exprBoolean(c.draft),
		"github.event.pull_request.head.ref":            exprText(c.ref),
		"github.head_ref":                               exprText(c.ref),
		"inputs." + reviewPrefix:                        exprText(prefix),
		"inputs.runs_on":                                exprText(runsOnDefault),
	}
	return func(path string) (exprValue, error) {
		if property, ok := known[strings.ToLower(path)]; ok {
			return property, nil
		}
		return exprValue{}, fmt.Errorf("the expression reads %s, which this test does not model", path)
	}
}
