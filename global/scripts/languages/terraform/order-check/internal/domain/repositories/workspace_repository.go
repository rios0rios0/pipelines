// Package repositories holds the port the ordering checker reads and
// rewrites a repository through.
package repositories

// WorkspaceRepository is a repository on disk, paths absolute.
type WorkspaceRepository interface {
	// Root is the repository, resolved.
	Root() string
	// Read is a file's text.
	Read(path string) (string, error)
	// Write replaces a file's text.
	Write(path, content string) error
	// IsFile is a regular file, following symlinks.
	IsFile(path string) bool
	// IsDir is a directory, following symlinks.
	IsDir(path string) bool
	// Named are the entries called `name` at any depth below `base`, in path
	// order, never descending into a symlink or an excluded directory.
	Named(base, name string) []string
	// Directories are the directories directly in `dir`, excluded ones left
	// out, in path order.
	Directories(dir string) []string
	// Matching are the entries directly in `dir` whose name matches the
	// shell-style `pattern`, in path order.
	Matching(dir, pattern string) []string
	// Excluded is a path under, or naming, a directory the checker never
	// reads: provider caches, the VCS directory, the pipelines checkout.
	Excluded(path string) bool
}
