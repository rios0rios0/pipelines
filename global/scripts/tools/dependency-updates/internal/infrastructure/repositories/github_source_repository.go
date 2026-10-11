package repositories

import (
	"encoding/json"
	"net/url"
	"strings"

	"github.com/rios0rios0/pipelines/global/scripts/tools/dependency-updates/internal/domain/entities"
	"github.com/rios0rios0/pipelines/global/scripts/tools/dependency-updates/internal/domain/repositories"
)

// maxTagDepth bounds how many annotated tags are followed to reach a commit.
const maxTagDepth = 5

// GitHubSourceRepository answers questions about an action's git history.
type GitHubSourceRepository struct {
	transport Transport
}

// NewGitHubSourceRepository builds the repository.
func NewGitHubSourceRepository(transport Transport) *GitHubSourceRepository {
	return &GitHubSourceRepository{transport: transport}
}

type gitObject struct {
	Object struct {
		Type string `json:"type"`
		SHA  string `json:"sha"`
	} `json:"object"`
}

func (r *GitHubSourceRepository) object(target string) (gitObject, error) {
	var answer gitObject
	content, err := r.transport.Get(target, GitHubHeaders(), MaxDocumentBytes)
	if err != nil {
		return answer, err
	}
	if decodeErr := json.Unmarshal(content, &answer); decodeErr != nil {
		return answer, repositories.NewLookupError("%s -> not JSON: %s", target, decodeErr)
	}
	return answer, nil
}

// TagCommit is the commit a release tag points at. An annotated tag's ref names
// a TAG OBJECT, not a commit, and pinning that object's SHA would read
// correctly and resolve to nothing a runner can check out, so the chain is
// followed to the commit.
func (r *GitHubSourceRepository) TagCommit(repository, tag string) (string, error) {
	target, err := r.object(gitHubAPI + "/repos/" + repository + "/git/ref/tags/" + escapePath(tag))
	if err != nil {
		return "", err
	}
	for range maxTagDepth {
		kind, sha := target.Object.Type, target.Object.SHA
		if kind == "commit" {
			if !entities.CommitSHA.MatchString(sha) {
				return "", repositories.NewLookupError("%s@%s -> %q is not a commit SHA", repository, tag, sha)
			}
			return sha, nil
		}
		if kind != "tag" || !entities.CommitSHA.MatchString(sha) {
			if kind == "" {
				kind = "nothing"
			}
			return "", repositories.NewLookupError("%s@%s points at %s, not a commit", repository, tag, kind)
		}
		if target, err = r.object(gitHubAPI + "/repos/" + repository + "/git/tags/" + sha); err != nil {
			return "", err
		}
	}
	return "", repositories.NewLookupError("%s@%s -> tag chain too deep to dereference", repository, tag)
}

// Compare relates two commits the way GitHub's compare view does.
func (r *GitHubSourceRepository) Compare(repository, base, head string) (entities.Comparison, error) {
	target := gitHubAPI + "/repos/" + repository + "/compare/" + base + "..." + head + "?per_page=1"
	content, err := r.transport.Get(target, GitHubHeaders(), MaxPackumentBytes)
	if err != nil {
		return entities.Comparison{}, err
	}
	var answer struct {
		Status  string            `json:"status"`
		AheadBy int               `json:"ahead_by"`
		Files   []json.RawMessage `json:"files"`
	}
	if decodeErr := json.Unmarshal(content, &answer); decodeErr != nil {
		return entities.Comparison{}, repositories.NewLookupError("%s -> not JSON: %s", target, decodeErr)
	}
	return entities.Comparison{Status: answer.Status, AheadBy: answer.AheadBy, Files: len(answer.Files)}, nil
}

// escapePath escapes each segment of a path and keeps its slashes.
func escapePath(path string) string {
	segments := strings.Split(path, "/")
	for index, segment := range segments {
		segments[index] = url.PathEscape(segment)
	}
	return strings.Join(segments, "/")
}
