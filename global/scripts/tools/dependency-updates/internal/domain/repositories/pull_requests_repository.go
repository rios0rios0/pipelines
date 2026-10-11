package repositories

import "github.com/rios0rios0/pipelines/global/scripts/tools/dependency-updates/internal/domain/entities"

// PullRequestsRepository reads the update branch's pull requests and commits.
type PullRequestsRepository interface {
	// ClosedPullRequests are the closed pull requests opened from `branch`.
	ClosedPullRequests(repository, branch string) ([]entities.PullRequest, error)
	// BranchCommits are the commits on `branch` that `base` lacks; a NotFound
	// error when the branch does not exist yet.
	BranchCommits(repository, base, branch string) ([]entities.Commit, error)
}
