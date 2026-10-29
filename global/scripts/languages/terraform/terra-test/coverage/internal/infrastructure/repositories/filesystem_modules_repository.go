// Package repositories holds the filesystem adapter the coverage report
// reads a checkout through.
package repositories

import (
	"errors"
	"slices"
	"strconv"
	"strings"
	"syscall"
	"unicode"
	"unicode/utf8"

	"github.com/rios0rios0/pipelines/global/scripts/languages/terraform/internal/paths"
	"github.com/rios0rios0/pipelines/global/scripts/languages/terraform/internal/text"
	"github.com/rios0rios0/pipelines/global/scripts/languages/terraform/terra-test/coverage/internal/domain/repositories"
)

// vendored are copies of modules that already live in the source tree,
// excluded from the file walk and from module discovery alike, at any depth:
// counting them inflates the denominator AND duplicates the successes, which
// once made one module appear six times at 100%. Measured on the reference
// repositories, `.terraform` copies were 62 of 98 `.tf` files in one and 122
// of 443 in the other.
func vendored() []string {
	return []string{".terraform", ".terragrunt-cache", ".external_modules", ".git"}
}

// pruned are left out of the file walk only. An `examples/` tree is example
// USAGE of a module, not module code: in the root layout it would land in the
// denominator and deflate every module that ships examples. It is NOT left
// out of module discovery -- a module legitimately named `modules/examples/`
// is a module, and skipping it would hide it.
func pruned(skipTests bool) []string {
	names := append(vendored(), "examples")
	if skipTests {
		names = append(names, "tests")
	}
	return names
}

// FilesystemModulesRepository is a checkout on disk.
type FilesystemModulesRepository struct {
	root string
}

// NewFilesystemModulesRepository opens the checkout at `root`, already resolved.
func NewFilesystemModulesRepository(root string) *FilesystemModulesRepository {
	return &FilesystemModulesRepository{root: root}
}

// Modules handles both repository layouts. `modules/<name>/` is the
// monorepo layout; when there is no such tree but the root itself holds
// `*.tf`, the repository IS the module -- the module-per-repository layout --
// which would otherwise score a whole published module 0/0.
func (r *FilesystemModulesRepository) Modules() []string {
	modulesRoot := paths.Join(r.root, "modules")
	if paths.IsDir(modulesRoot) {
		var found []string
		for _, child := range paths.Children(modulesRoot) {
			if paths.IsDir(child) && !paths.IsSymlink(child) && !slices.Contains(vendored(), paths.Base(child)) {
				found = append(found, child)
			}
		}
		if len(found) > 0 {
			return found
		}
	}
	if len(paths.Glob(r.root, "*.tf")) > 0 {
		return []string{r.root}
	}
	return nil
}

// Sources walks a module for its `.tf` files, never following a symlink,
// test code and vendored copies left out.
func (r *FilesystemModulesRepository) Sources(module string) ([]repositories.Source, []string) {
	var files []string
	pending := []string{module}
	for len(pending) > 0 {
		next := pending[len(pending)-1]
		pending = pending[:len(pending)-1]
		for _, entry := range paths.Children(next) {
			if paths.IsSymlink(entry) {
				continue
			}
			if paths.IsDir(entry) {
				if !slices.Contains(pruned(true), paths.Base(entry)) {
					pending = append(pending, entry)
				}
				continue
			}
			if strings.HasSuffix(paths.Base(entry), ".tf") {
				files = append(files, entry)
			}
		}
	}
	paths.Sort(files)
	var (
		sources  []repositories.Source
		warnings []string
	)
	for _, file := range files {
		content, warning := read(file)
		if warning != "" {
			warnings = append(warnings, warning)
			continue
		}
		relative, _ := paths.RelativeTo(file, r.root)
		namespace, _ := paths.RelativeTo(paths.Dir(file), module)
		sources = append(sources, repositories.Source{Path: relative, Namespace: namespace, Text: content})
	}
	return sources, warnings
}

// Tests reads `tests/*.tftest.hcl` -- the same non-recursive glob the
// terra-test tier selects its tests with, so a test it never runs never
// credits coverage -- regular files only, symlinks left out.
func (r *FilesystemModulesRepository) Tests(module string) ([]string, []string, bool) {
	var files []string
	for _, file := range paths.Glob(paths.Join(module, "tests"), "*.tftest.hcl") {
		if paths.IsFile(file) && !paths.IsSymlink(file) {
			files = append(files, file)
		}
	}
	var (
		tests    []string
		warnings []string
	)
	for _, file := range files {
		content, warning := read(file)
		if warning != "" {
			warnings = append(warnings, warning)
			continue
		}
		tests = append(tests, content)
	}
	return tests, warnings, len(files) > 0
}

// read is a file's text, or the warning saying why it could not be read --
// an unreadable file is never a failure, the report goes on without it.
func read(path string) (string, string) {
	content, err := text.ReadReplacing(path)
	if err != nil {
		return "", "warning: cannot read " + path + ": " + describe(err, path)
	}
	return content, ""
}

// describe states a file error the way the report's earlier implementation
// did: `[Errno 13] Permission denied: '<path>'`.
func describe(err error, path string) string {
	var errno syscall.Errno
	if !errors.As(err, &errno) {
		return err.Error()
	}
	message := errno.Error()
	if first, width := utf8.DecodeRuneInString(message); width > 0 {
		message = string(unicode.ToUpper(first)) + message[width:]
	}
	return "[Errno " + strconv.Itoa(int(errno)) + "] " + message + ": " + text.Repr(path)
}
