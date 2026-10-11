package repositories

import (
	"io/fs"
	"os"
	"path"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"unicode/utf8"
)

// newFileMode is the mode a file the run creates is given (a changelog
// fragment); a file that exists keeps its own.
const newFileMode = 0o600

// newDirectoryMode is the mode a directory the run creates is given.
const newDirectoryMode = 0o750

// skipDirs are never scanned. `.pipelines` is where a consumer running the
// checker by hand may check THIS library out inside their repository: without
// the skip, their report would list this library's pins as their own, and
// `--apply` would rewrite a checkout they do not own.
func skipDirs() []string {
	return []string{".git", "node_modules", "build", ".terraform", ".pipelines"}
}

// FileWorkspaceRepository is a repository's pinned files, read once and edited
// in memory. Discovery and `--apply` read the same files, so a pin is rewritten
// in exactly the text it was discovered in, and every file is written back at
// most once, after every edit to it has succeeded.
//
// Contents are bytes as they are on disk, so a CRLF file stays CRLF and the
// only bytes that change are the ones an edit names. Two kinds of file are
// scanned but never written: one that is not valid UTF-8, because rewriting it
// through a replacement character would corrupt the parts nobody asked to
// touch; and a symlink, because writing through one edits whatever it points
// at. Every access goes through an [os.Root], so neither a path nor a symlink
// can reach outside the repository.
type FileWorkspaceRepository struct {
	root        string
	handle      *os.Root
	yaml        []string
	dockerfiles []string

	mutex      sync.Mutex
	original   map[string]*string
	current    map[string]string
	unwritable map[string]bool
}

// NewFileWorkspaceRepository opens the repository at `root` and lists the
// files it scans.
func NewFileWorkspaceRepository(root string) (*FileWorkspaceRepository, error) {
	handle, err := os.OpenRoot(root)
	if err != nil {
		return nil, err
	}
	workspace := &FileWorkspaceRepository{
		root: root, handle: handle,
		original: make(map[string]*string), current: make(map[string]string), unwritable: make(map[string]bool),
	}
	workspace.walk(".")
	return workspace, nil
}

// walk lists a directory's files before descending into its subdirectories,
// each in name order -- the order every report was written in before.
func (w *FileWorkspaceRepository) walk(directory string) {
	entries, err := os.ReadDir(filepath.Join(w.root, filepath.FromSlash(directory)))
	if err != nil {
		return
	}
	var subdirectories []string
	for _, entry := range entries {
		relative := path.Join(directory, entry.Name())
		if w.isDirectory(entry, relative) {
			// A symlink to a directory is listed but never descended into.
			if entry.Type()&fs.ModeSymlink == 0 && !slices.Contains(skipDirs(), entry.Name()) {
				subdirectories = append(subdirectories, relative)
			}
			continue
		}
		if strings.HasSuffix(entry.Name(), ".yaml") || strings.HasSuffix(entry.Name(), ".yml") {
			w.yaml = append(w.yaml, relative)
		}
		if strings.HasPrefix(entry.Name(), "Dockerfile") {
			w.dockerfiles = append(w.dockerfiles, relative)
		}
	}
	for _, subdirectory := range subdirectories {
		w.walk(subdirectory)
	}
}

func (w *FileWorkspaceRepository) isDirectory(entry fs.DirEntry, relative string) bool {
	if entry.Type()&fs.ModeSymlink == 0 {
		return entry.IsDir()
	}
	info, err := os.Stat(filepath.Join(w.root, filepath.FromSlash(relative)))
	return err == nil && info.IsDir()
}

// Root is the repository's directory.
func (w *FileWorkspaceRepository) Root() string {
	return w.root
}

// YAMLFiles are the repository's YAML files.
func (w *FileWorkspaceRepository) YAMLFiles() []string {
	return w.yaml
}

// Dockerfiles are the repository's Dockerfiles.
func (w *FileWorkspaceRepository) Dockerfiles() []string {
	return w.dockerfiles
}

// Text is a file's current contents; empty when it does not exist.
func (w *FileWorkspaceRepository) Text(file string) string {
	w.mutex.Lock()
	defer w.mutex.Unlock()
	return w.load(file)
}

func (w *FileWorkspaceRepository) load(file string) string {
	if text, loaded := w.current[file]; loaded {
		return text
	}
	if info, err := w.handle.Lstat(filepath.FromSlash(file)); err == nil && info.Mode()&fs.ModeSymlink != 0 {
		w.unwritable[file] = true
	}
	content, err := w.handle.ReadFile(filepath.FromSlash(file))
	if err != nil {
		w.original[file] = nil
		w.current[file] = ""
		return ""
	}
	text := string(content)
	if !utf8.ValidString(text) {
		w.unwritable[file] = true
	}
	w.original[file] = &text
	w.current[file] = text
	return text
}

// Set replaces a file's contents in memory; false when the file is one that is
// never written.
func (w *FileWorkspaceRepository) Set(file, text string) bool {
	w.mutex.Lock()
	defer w.mutex.Unlock()
	w.load(file)
	if w.unwritable[file] {
		return false
	}
	w.current[file] = text
	return true
}

// IsFile is true for an existing regular file (or a symlink to one).
func (w *FileWorkspaceRepository) IsFile(file string) bool {
	info, err := w.handle.Stat(filepath.FromSlash(file))
	return err == nil && info.Mode().IsRegular()
}

// IsDir is true for an existing directory.
func (w *FileWorkspaceRepository) IsDir(directory string) bool {
	info, err := w.handle.Stat(filepath.FromSlash(directory))
	return err == nil && info.IsDir()
}

// Changed lists the files whose contents differ from disk, in name order.
func (w *FileWorkspaceRepository) Changed() []string {
	w.mutex.Lock()
	defer w.mutex.Unlock()
	var changed []string
	for file, text := range w.current {
		original := w.original[file]
		if (original == nil && text != "") || (original != nil && *original != text) {
			changed = append(changed, file)
		}
	}
	slices.Sort(changed)
	return changed
}

// Write writes every changed file back and lists them.
func (w *FileWorkspaceRepository) Write() ([]string, error) {
	changed := w.Changed()
	for _, file := range changed {
		native := filepath.FromSlash(file)
		if err := w.handle.MkdirAll(filepath.Dir(native), newDirectoryMode); err != nil {
			return nil, err
		}
		if err := w.handle.WriteFile(native, []byte(w.current[file]), newFileMode); err != nil {
			return nil, err
		}
		text := w.current[file]
		w.original[file] = &text
	}
	return changed, nil
}

// Close releases the repository handle.
func (w *FileWorkspaceRepository) Close() error {
	return w.handle.Close()
}
