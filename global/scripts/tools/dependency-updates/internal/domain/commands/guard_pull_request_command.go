package commands

import (
	"fmt"
	"strings"

	"github.com/rios0rios0/pipelines/global/scripts/tools/dependency-updates/internal/domain/entities"
	"github.com/rios0rios0/pipelines/global/scripts/tools/dependency-updates/internal/domain/repositories"
)

// GuardDecision says whether the update branch may be regenerated, and why.
type GuardDecision struct {
	Proceed bool
	Reason  string
}

// GuardPullRequestCommand decides whether the workflow may rewrite its pull
// request's branch.
//
// The branch is regenerated from the default branch on every run -- a
// force-push -- so two situations make that wrong, and both are decisions a
// person made that would otherwise be silently undone:
//
//	DECLINED     a pull request proposing this exact set of updates was closed
//	             without merging; proposing it again twice a week would turn a
//	             "no" into a nag
//	HAND-EDITED  the branch carries a commit somebody pushed: any non-merge
//	             commit without the fingerprint trailer the workflow writes
//
// A lookup that fails decides nothing: not knowing whether a person declined
// something is not permission to propose it again.
type GuardPullRequestCommand struct {
	pulls repositories.PullRequestsRepository
}

// NewGuardPullRequestCommand builds the guard.
func NewGuardPullRequestCommand(pulls repositories.PullRequestsRepository) *GuardPullRequestCommand {
	return &GuardPullRequestCommand{pulls: pulls}
}

// Execute decides for the update `branch` of `repository`, proposing the set
// `fingerprint` against `base`.
func (c *GuardPullRequestCommand) Execute(repository, branch, base, fingerprint string) (GuardDecision, error) {
	closed, err := c.pulls.ClosedPullRequests(repository, branch)
	if err != nil {
		return GuardDecision{}, err
	}
	marker := entities.MarkerComment(fingerprint)
	for _, pull := range closed {
		if !pull.Merged && strings.Contains(pull.Body, marker) {
			return GuardDecision{
				Reason: fmt.Sprintf("these exact updates were declined in #%d, which was closed without "+
					"merging; they are proposed again once upstream releases something newer", pull.Number),
			}, nil
		}
	}
	commits, err := c.pulls.BranchCommits(repository, base, branch)
	if repositories.IsNotFound(err) {
		return GuardDecision{Proceed: true, Reason: "the branch does not exist yet"}, nil
	}
	if err != nil {
		return GuardDecision{}, err
	}
	for _, commit := range commits {
		// Merge commits are exempt: GitHub's "Update branch" button makes one,
		// and regenerating the branch only redoes what it did.
		if commit.Parents > 1 || strings.Contains(commit.Message, entities.FingerprintTrailer) {
			continue
		}
		return GuardDecision{
			Reason: fmt.Sprintf("%s carries %s, a commit this workflow did not write; the branch is left "+
				"alone until its pull request is merged or closed", branch, commit.SHA[:min(len(commit.SHA), digestPreview)]),
		}, nil
	}
	return GuardDecision{Proceed: true, Reason: "the branch holds only this workflow's own commits"}, nil
}
