// Package doubles holds handwritten test doubles for the ordering checker's
// port. No mocking library: the double implements the port the way a test
// needs a repository to behave.
package doubles

import (
	"maps"
	"slices"
	"strings"

	"github.com/rios0rios0/pipelines/global/scripts/languages/terraform/internal/paths"
)

// InMemoryWorkspace is a repository held in a map of absolute path to text;
// a directory exists when a file lies below it.
type InMemoryWorkspace struct {
	Files  map[string]string
	Writes []string
	root   string
}

// NewInMemoryWorkspace holds `files`, named relative to `/repo`.
func NewInMemoryWorkspace(files map[string]string) *InMemoryWorkspace {
	held := map[string]string{}
	for name, content := range files {
		held[paths.Join("/repo", name)] = content
	}
	return &InMemoryWorkspace{Files: held, root: "/repo"}
}

// Root is `/repo`.
func (w *InMemoryWorkspace) Root() string { return w.root }

// Read is a held file's text.
func (w *InMemoryWorkspace) Read(path string) (string, error) { return w.Files[path], nil }

// Write holds a file's new text and records the write.
func (w *InMemoryWorkspace) Write(path, content string) error {
	w.Files[path] = content
	w.Writes = append(w.Writes, path)
	return nil
}

// IsFile is a held file.
func (w *InMemoryWorkspace) IsFile(path string) bool {
	_, held := w.Files[path]
	return held
}

// IsDir is a directory some held file lies below.
func (w *InMemoryWorkspace) IsDir(path string) bool {
	for file := range w.Files {
		if strings.HasPrefix(file, path+"/") {
			return true
		}
	}
	return false
}

// Excluded is a path through `.terraform`, `.git` or `.pipelines`.
func (w *InMemoryWorkspace) Excluded(path string) bool {
	return paths.HasPart(path, ".terraform", ".git", ".pipelines")
}

// Named are the held files called `name` below `base`, not excluded.
func (w *InMemoryWorkspace) Named(base, name string) []string {
	var found []string
	for _, file := range w.sorted() {
		if strings.HasPrefix(file, base+"/") && paths.Base(file) == name && !w.Excluded(file) {
			found = append(found, file)
		}
	}
	return found
}

// Directories are the directories directly in `dir`.
func (w *InMemoryWorkspace) Directories(dir string) []string {
	seen := map[string]bool{}
	for _, file := range w.sorted() {
		rest, below := strings.CutPrefix(file, dir+"/")
		if !below || !strings.Contains(rest, "/") {
			continue
		}
		child := paths.Join(dir, rest[:strings.IndexByte(rest, '/')])
		if !w.Excluded(child) {
			seen[child] = true
		}
	}
	found := slices.Collect(maps.Keys(seen))
	paths.Sort(found)
	return found
}

// Matching are the held files directly in `dir` matching `pattern`.
func (w *InMemoryWorkspace) Matching(dir, pattern string) []string {
	var found []string
	for _, file := range w.sorted() {
		if paths.Dir(file) == dir && paths.Match(paths.Base(file), pattern) {
			found = append(found, file)
		}
	}
	return found
}

func (w *InMemoryWorkspace) sorted() []string {
	files := slices.Collect(maps.Keys(w.Files))
	paths.Sort(files)
	return files
}
