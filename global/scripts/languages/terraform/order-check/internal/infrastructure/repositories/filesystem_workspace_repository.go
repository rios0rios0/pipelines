// Package repositories holds the filesystem adapter the ordering checker
// reads and rewrites a checkout through.
package repositories

import (
	"github.com/rios0rios0/pipelines/global/scripts/languages/terraform/internal/paths"
	"github.com/rios0rios0/pipelines/global/scripts/languages/terraform/internal/text"
)

// excluded are never read: provider plugin caches, the repository's own VCS
// directory, and the `.pipelines` checkout the GitHub workflow clones the
// shared scripts into -- scanning it would lint this library instead of the
// consumer.
func excluded() []string {
	return []string{".terraform", ".git", ".pipelines"}
}

// FilesystemWorkspaceRepository is a checkout on disk.
type FilesystemWorkspaceRepository struct {
	root string
}

// NewFilesystemWorkspaceRepository opens the checkout at `root`, resolved.
func NewFilesystemWorkspaceRepository(root string) *FilesystemWorkspaceRepository {
	return &FilesystemWorkspaceRepository{root: root}
}

// Root is the checkout.
func (r *FilesystemWorkspaceRepository) Root() string { return r.root }

// Read is a file's text, refusing one that is not UTF-8.
func (r *FilesystemWorkspaceRepository) Read(path string) (string, error) {
	return text.ReadStrict(path)
}

// Write replaces a file's text.
func (r *FilesystemWorkspaceRepository) Write(path, content string) error {
	return text.Write(path, content)
}

// IsFile is a regular file, following symlinks.
func (r *FilesystemWorkspaceRepository) IsFile(path string) bool { return paths.IsFile(path) }

// IsDir is a directory, following symlinks.
func (r *FilesystemWorkspaceRepository) IsDir(path string) bool { return paths.IsDir(path) }

// Excluded is a path any of whose components -- above the checkout too -- is
// an excluded directory.
func (r *FilesystemWorkspaceRepository) Excluded(path string) bool {
	return paths.HasPart(path, excluded()...)
}

// Named finds the entries called `name` below `base`.
func (r *FilesystemWorkspaceRepository) Named(base, name string) []string {
	var found []string
	for _, path := range paths.RGlob(base, name, excluded()...) {
		if !r.Excluded(path) {
			found = append(found, path)
		}
	}
	return found
}

// Directories are the directories directly in `dir`.
func (r *FilesystemWorkspaceRepository) Directories(dir string) []string {
	var found []string
	for _, child := range paths.Children(dir) {
		if paths.IsDir(child) && !r.Excluded(child) {
			found = append(found, child)
		}
	}
	return found
}

// Matching are the entries of `dir` matching `pattern`.
func (r *FilesystemWorkspaceRepository) Matching(dir, pattern string) []string {
	return paths.Glob(dir, pattern)
}
