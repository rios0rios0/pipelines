// Package commands holds what the test-pyramid check does: judge a pull request's suites.
package commands

import (
	"errors"
	"fmt"
	"maps"
	"slices"
	"strings"

	"github.com/rios0rios0/pipelines/global/scripts/tools/test-pyramid/internal/domain/entities"
	"github.com/rios0rios0/pipelines/global/scripts/tools/test-pyramid/internal/domain/repositories"
)

// JudgeTestPyramidCommand judges whether a pull request worsens its repository's test pyramid: it
// classifies every test case of the target branch (the merge base) and of the pull request, with
// the target branch's policy, and judges each suite by the book (entities.Judge).
type JudgeTestPyramidCommand struct {
	revisions repositories.RevisionsRepository
	trees     repositories.TreesRepository
	profiles  map[string]entities.Profile
}

// JudgeTestPyramidCommandListeners are the outcomes of a judgement; exactly one is called. OnError
// means the judgement could not be made, never that a pull request worsens the pyramid.
type JudgeTestPyramidCommandListeners struct {
	OnKept     func(report entities.Report)
	OnWorsened func(report entities.Report)
	OnError    func(err error)
}

// NewJudgeTestPyramidCommand wires the command to the repository it reads and the profiles it
// classifies with.
func NewJudgeTestPyramidCommand(
	revisions repositories.RevisionsRepository,
	trees repositories.TreesRepository,
	profiles map[string]entities.Profile,
) *JudgeTestPyramidCommand {
	return &JudgeTestPyramidCommand{revisions: revisions, trees: trees, profiles: profiles}
}

// Execute judges the pull request the request describes and calls the listener of the outcome.
func (c *JudgeTestPyramidCommand) Execute(request entities.Request, listeners JudgeTestPyramidCommandListeners) {
	report, err := c.judge(request)
	switch {
	case err != nil:
		listeners.OnError(err)
	case len(report.Worsened()) > 0:
		listeners.OnWorsened(report)
	default:
		listeners.OnKept(report)
	}
}

func (c *JudgeTestPyramidCommand) judge(request entities.Request) (entities.Report, error) {
	head, err := c.revisions.FindHead()
	if err != nil {
		return entities.Report{}, fmt.Errorf("HEAD is not a commit: %w", err)
	}
	base, err := c.base(request)
	if err != nil {
		return entities.Report{}, err
	}
	policy, found, err := c.policy(base.Commit, "the target branch")
	if err != nil {
		// Never a fallback to the pull request's policy, which would let a pull request choose its
		// own rules whenever the target's are broken. So a broken target fails every pull request,
		// the one that fixes it included, and says how out.
		return entities.Report{}, fmt.Errorf("%w\nEvery pull request fails this check until the target branch's %s "+
			"is fixed, the one that fixes it included: merge that fix past this check", err, entities.PolicyFile)
	}
	// The pull request's own `.test-pyramid` decides nothing; it is read so that an invalid one
	// cannot be merged unnoticed, and so the report can say a change applies once it is merged.
	headPolicy, _, err := c.policy(head, "this pull request")
	if err != nil {
		return entities.Report{}, err
	}
	languages := policy.Languages
	if len(languages) == 0 {
		languages = request.Languages
	}
	if len(languages) == 0 {
		return entities.Report{}, errors.New(
			"no suite to judge: set TEST_PYRAMID_LANGUAGE, or `languages` in .test-pyramid",
		)
	}
	report := entities.Report{
		Target:        request.Target,
		Base:          base,
		Head:          head,
		Policy:        policy,
		PolicyFound:   found,
		PolicyChanged: policy.String() != headPolicy.String(),
		Blocking:      policy.Blocking || request.ForceBlocking,
	}
	for _, language := range unique(languages) {
		suite, suiteErr := c.suite(language, base.Commit, head, policy)
		if suiteErr != nil {
			return entities.Report{}, suiteErr
		}
		report.Suites = append(report.Suites, suite)
	}
	return report, nil
}

// base is the commit the request names, or the merge base with its target branch.
func (c *JudgeTestPyramidCommand) base(request entities.Request) (entities.Base, error) {
	if request.Base == "" {
		return c.revisions.FindMergeBase(request.Target)
	}
	commit, err := c.revisions.FindCommit(request.Base)
	if err != nil {
		return entities.Base{}, fmt.Errorf(
			"TEST_PYRAMID_BASE names %q, which is not a commit here: %w",
			request.Base,
			err,
		)
	}
	return entities.Base{Commit: commit, Description: "TEST_PYRAMID_BASE"}, nil
}

// policy is the `.test-pyramid` of a commit, the default policy when it has none, and whether it
// has one. An invalid one stops the judgement: its rules would otherwise be silently dropped.
func (c *JudgeTestPyramidCommand) policy(commit, where string) (entities.Policy, bool, error) {
	text, found, err := c.trees.FindFileByPath(commit, entities.PolicyFile)
	if err != nil {
		return entities.Policy{}, false, fmt.Errorf("cannot read the %s of %s: %w", entities.PolicyFile, where, err)
	}
	if !found {
		return entities.DefaultPolicy(), false, nil
	}
	policy, err := entities.ParsePolicy(text)
	if err != nil {
		return entities.Policy{}, true, fmt.Errorf("the %s of %s is invalid:\n%w", entities.PolicyFile, where, err)
	}
	return policy, true, nil
}

func (c *JudgeTestPyramidCommand) suite(language, base, head string, policy entities.Policy) (entities.Suite, error) {
	profile, known := c.profiles[language]
	if !known {
		return entities.Suite{}, fmt.Errorf("no test-pyramid profile for %q (known: %s)",
			language, strings.Join(slices.Sorted(maps.Keys(c.profiles)), ", "))
	}
	target, err := c.classify(profile, base, policy.Rules)
	if err != nil {
		return entities.Suite{}, err
	}
	pullRequest, err := c.classify(profile, head, policy.Rules)
	if err != nil {
		return entities.Suite{}, err
	}
	return entities.Suite{
		Verdict:     entities.Judge(language, target.Counts, pullRequest.Counts, policy.Mix),
		Target:      target,
		PullRequest: pullRequest,
	}, nil
}

func (c *JudgeTestPyramidCommand) classify(
	profile entities.Profile, commit string, rules []entities.PathRule,
) (entities.Classification, error) {
	files, err := c.trees.FindAllFilesByFilter(commit, profile.Reads)
	if err != nil {
		return entities.Classification{}, fmt.Errorf(
			"cannot read the %s test files of %s: %w",
			profile.Language,
			commit,
			err,
		)
	}
	return profile.Classify(files, rules), nil
}

// unique is the names in their first order, each once.
func unique(names []string) []string {
	var kept []string
	for _, name := range names {
		if !slices.Contains(kept, name) {
			kept = append(kept, name)
		}
	}
	return kept
}
