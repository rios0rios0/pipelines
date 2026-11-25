package repositories

import "github.com/rios0rios0/pipelines/global/scripts/tools/test-pyramid/internal/domain/entities"

// TreesRepository reads a commit's tree without checking it out, so both trees of a pull request
// are read from the same working copy.
type TreesRepository interface {
	// FindFileByPath is a file's content at a commit, and whether the commit holds it.
	FindFileByPath(commit, path string) (string, bool, error)
	// FindAllFilesByFilter are the files of a commit that `keep` accepts, with their content, in
	// path order. Binary files and links are left out.
	FindAllFilesByFilter(commit string, keep func(path string) bool) ([]entities.TestFile, error)
}
