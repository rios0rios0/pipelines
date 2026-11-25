// Package doubles holds handwritten test doubles for the test-pyramid check's ports. No mocking
// library: each double implements a port the way a test needs a repository to behave.
package doubles

import (
	"errors"
	"maps"
	"slices"

	"github.com/rios0rios0/pipelines/global/scripts/tools/test-pyramid/internal/domain/entities"
)

// ErrUnreadable is what a double answers when a test makes it fail.
var ErrUnreadable = errors.New("unreadable")

// InMemoryTreesRepository holds trees as maps of path to content, by commit.
type InMemoryTreesRepository struct {
	trees      map[string]map[string]string
	unreadable map[string]bool
}

// NewInMemoryTreesRepository holds the trees, keyed by commit.
func NewInMemoryTreesRepository(trees map[string]map[string]string) *InMemoryTreesRepository {
	return &InMemoryTreesRepository{trees: trees, unreadable: map[string]bool{}}
}

// WithUnreadable makes every read of a commit fail.
func (r *InMemoryTreesRepository) WithUnreadable(commit string) *InMemoryTreesRepository {
	r.unreadable[commit] = true
	return r
}

// FindFileByPath is a held file, and whether the commit holds it.
func (r *InMemoryTreesRepository) FindFileByPath(commit, path string) (string, bool, error) {
	if r.unreadable[commit] {
		return "", false, ErrUnreadable
	}
	content, found := r.trees[commit][path]
	return content, found, nil
}

// FindAllFilesByFilter are the held files of a commit that `keep` accepts, in path order.
func (r *InMemoryTreesRepository) FindAllFilesByFilter(
	commit string,
	keep func(string) bool,
) ([]entities.TestFile, error) {
	if r.unreadable[commit] {
		return nil, ErrUnreadable
	}
	files := []entities.TestFile{}
	for _, path := range slices.Sorted(maps.Keys(r.trees[commit])) {
		if keep(path) {
			files = append(files, entities.TestFile{Path: path, Content: r.trees[commit][path]})
		}
	}
	return files, nil
}

// StubRevisionsRepository answers with the commits it was given.
type StubRevisionsRepository struct {
	head      string
	mergeBase entities.Base
	commits   map[string]string
	err       error
}

// NewStubRevisionsRepository has HEAD at `head`, merging into a target whose merge base is `base`.
func NewStubRevisionsRepository(head, base string) *StubRevisionsRepository {
	return &StubRevisionsRepository{
		head:      head,
		mergeBase: entities.Base{Commit: base, Description: `the merge base with "main"`},
		commits:   map[string]string{},
	}
}

// WithCommit makes `revision` name `commit`.
func (r *StubRevisionsRepository) WithCommit(revision, commit string) *StubRevisionsRepository {
	r.commits[revision] = commit
	return r
}

// WithError makes every answer fail.
func (r *StubRevisionsRepository) WithError(err error) *StubRevisionsRepository {
	r.err = err
	return r
}

// FindHead is the stubbed HEAD.
func (r *StubRevisionsRepository) FindHead() (string, error) {
	return r.head, r.err
}

// FindCommit is the commit a stubbed revision names.
func (r *StubRevisionsRepository) FindCommit(revision string) (string, error) {
	if commit, found := r.commits[revision]; found {
		return commit, r.err
	}
	return "", ErrUnreadable
}

// FindMergeBase is the stubbed merge base, whatever the target.
func (r *StubRevisionsRepository) FindMergeBase(string) (entities.Base, error) {
	return r.mergeBase, r.err
}
