package repositories

import (
	"fmt"
	"strings"

	"github.com/rios0rios0/pipelines/global/scripts/tools/test-pyramid/internal/domain/entities"
)

// GitRevisionsRepository resolves a pull request's commits in a git working copy whose `origin` is
// the repository the pull request targets.
type GitRevisionsRepository struct {
	git *gitRunner
}

// NewGitRevisionsRepository reads the working copy at `directory`.
func NewGitRevisionsRepository(directory string) (*GitRevisionsRepository, error) {
	git, err := newGitRunner(directory)
	if err != nil {
		return nil, err
	}
	return &GitRevisionsRepository{git: git}, nil
}

// FindHead is the commit checked out.
func (r *GitRevisionsRepository) FindHead() (string, error) {
	return r.git.output("rev-parse", "--verify", "--quiet", "HEAD^{commit}")
}

// FindCommit is the commit a revision names.
func (r *GitRevisionsRepository) FindCommit(revision string) (string, error) {
	return r.git.output("rev-parse", "--verify", "--quiet", "--end-of-options", revision+"^{commit}")
}

// FindDefaultBranch is the branch `origin/HEAD` names, or "" when the working copy records none.
func (r *GitRevisionsRepository) FindDefaultBranch() string {
	branch, err := r.git.output("symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD")
	if err != nil {
		return ""
	}
	return strings.TrimPrefix(branch, "origin/")
}

// FindMergeBase fetches the target branch from `origin`, so a target that moved since the pull
// request was opened is the one judged against, and is HEAD's merge base with it: changes the
// target gained since are not the pull request's. A shallow clone that does not reach the merge
// base is deepened once; failing that, the target's tip is used, with a warning.
func (r *GitRevisionsRepository) FindMergeBase(target string) (entities.Base, error) {
	if _, err := r.git.output("check-ref-format", "--branch", target); err != nil {
		return entities.Base{}, fmt.Errorf("%q is not a branch name", target)
	}
	ref := "refs/remotes/origin/" + target
	base := entities.Base{Description: fmt.Sprintf("the merge base with %q", target)}
	refspec := "+refs/heads/" + target + ":" + ref
	if _, err := r.git.output("fetch", "--quiet", "--no-tags", "origin", refspec); err != nil {
		if _, missing := r.FindCommit(ref); missing != nil {
			return entities.Base{}, fmt.Errorf(
				"cannot fetch %q from origin, and there is no earlier copy to compare with: %w", target, err)
		}
		base.Warning = fmt.Sprintf("could not fetch %q from origin; comparing with the copy fetched earlier", target)
	}
	commit, err := r.git.output("merge-base", "HEAD", ref)
	if err != nil && r.shallow() {
		if _, deepened := r.git.output(
			"fetch",
			"--quiet",
			"--no-tags",
			"--unshallow",
			"origin",
			refspec,
		); deepened == nil {
			commit, err = r.git.output("merge-base", "HEAD", ref)
		}
	}
	if err != nil {
		tip, tipErr := r.FindCommit(ref)
		if tipErr != nil {
			return entities.Base{}, fmt.Errorf("%q cannot be resolved: %w", target, tipErr)
		}
		base.Commit = tip
		base.Description = fmt.Sprintf("the tip of %q", target)
		base.Warning = fmt.Sprintf("no merge base with %q; comparing with its tip, "+
			"so its changes since this branch began count as this pull request's", target)
		return base, nil
	}
	base.Commit = commit
	return base, nil
}

func (r *GitRevisionsRepository) shallow() bool {
	shallow, err := r.git.output("rev-parse", "--is-shallow-repository")
	return err == nil && shallow == "true"
}
