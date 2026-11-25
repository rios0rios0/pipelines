// Package repositories holds the ports the test-pyramid check reads a repository through.
package repositories

import "github.com/rios0rios0/pipelines/global/scripts/tools/test-pyramid/internal/domain/entities"

// RevisionsRepository resolves the two commits a pull request is judged between.
type RevisionsRepository interface {
	// FindHead is the commit checked out, the pull request applied.
	FindHead() (string, error)
	// FindCommit is the commit a revision names.
	FindCommit(revision string) (string, error)
	// FindMergeBase brings the target branch up to date and is the merge base of the head with it,
	// or the target's tip, with a warning, when no merge base can be found.
	FindMergeBase(target string) (entities.Base, error)
}
