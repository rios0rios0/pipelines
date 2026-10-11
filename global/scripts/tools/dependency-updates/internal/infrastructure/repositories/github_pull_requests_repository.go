package repositories

import (
	"encoding/json"
	"net/url"
	"strings"

	"github.com/rios0rios0/pipelines/global/scripts/tools/dependency-updates/internal/domain/entities"
	"github.com/rios0rios0/pipelines/global/scripts/tools/dependency-updates/internal/domain/repositories"
)

// GitHubPullRequestsRepository reads the update branch's pull requests and
// commits through the REST API.
type GitHubPullRequestsRepository struct {
	transport Transport
	api       string
}

// NewGitHubPullRequestsRepository builds the reader against `api` (GitHub
// Enterprise Server answers on its own host).
func NewGitHubPullRequestsRepository(transport Transport, api string) *GitHubPullRequestsRepository {
	return &GitHubPullRequestsRepository{transport: transport, api: strings.TrimRight(api, "/")}
}

// ClosedPullRequests are the closed pull requests opened from `branch`.
func (r *GitHubPullRequestsRepository) ClosedPullRequests(repository, branch string) ([]entities.PullRequest, error) {
	owner, _, _ := strings.Cut(repository, "/")
	target := r.api + reposPath + repository + "/pulls?state=closed&head=" +
		url.QueryEscape(owner+":"+branch) + "&per_page=100"
	content, err := r.transport.Get(target, GitHubHeaders(), MaxDocumentBytes)
	if err != nil {
		return nil, err
	}
	var listed []struct {
		Number   int     `json:"number"`
		MergedAt *string `json:"merged_at"`
		Body     *string `json:"body"`
	}
	if decodeErr := json.Unmarshal(content, &listed); decodeErr != nil {
		return nil, repositories.NewLookupError("%s -> not JSON: %s", target, decodeErr)
	}
	pulls := make([]entities.PullRequest, 0, len(listed))
	for _, pull := range listed {
		body := ""
		if pull.Body != nil {
			body = *pull.Body
		}
		pulls = append(pulls, entities.PullRequest{Number: pull.Number, Merged: pull.MergedAt != nil, Body: body})
	}
	return pulls, nil
}

// BranchCommits are the commits on `branch` that `base` lacks.
func (r *GitHubPullRequestsRepository) BranchCommits(repository, base, branch string) ([]entities.Commit, error) {
	target := r.api + reposPath + repository + "/compare/" + escapePath(base) + "..." + escapePath(branch)
	content, err := r.transport.Get(target, GitHubHeaders(), MaxPackumentBytes)
	if err != nil {
		return nil, err
	}
	var comparison struct {
		Commits []struct {
			SHA     string            `json:"sha"`
			Parents []json.RawMessage `json:"parents"`
			Commit  struct {
				Message string `json:"message"`
			} `json:"commit"`
		} `json:"commits"`
	}
	if decodeErr := json.Unmarshal(content, &comparison); decodeErr != nil {
		return nil, repositories.NewLookupError("%s -> not JSON: %s", target, decodeErr)
	}
	commits := make([]entities.Commit, 0, len(comparison.Commits))
	for _, commit := range comparison.Commits {
		commits = append(
			commits,
			entities.Commit{SHA: commit.SHA, Parents: len(commit.Parents), Message: commit.Commit.Message},
		)
	}
	return commits, nil
}
