// Package repositories holds the filesystem adapter the shared-variable
// generator reads and writes a checkout through.
package repositories

import (
	"errors"
	"io/fs"
	"os"

	"github.com/rios0rios0/pipelines/global/scripts/languages/terraform/internal/paths"
	"github.com/rios0rios0/pipelines/global/scripts/languages/terraform/internal/text"
	"github.com/rios0rios0/pipelines/global/scripts/languages/terraform/var-catalog/internal/domain/entities"
)

// vendored is the directory `terraform init` vendors module sources into:
// other repositories' files, never a stack of this one.
const vendored = ".terraform"

// FilesystemStacksRepository is a checkout on disk.
type FilesystemStacksRepository struct {
	root string
}

// NewFilesystemStacksRepository opens the checkout at `root`, already resolved.
func NewFilesystemStacksRepository(root string) *FilesystemStacksRepository {
	return &FilesystemStacksRepository{root: root}
}

// Root is the checkout's resolved path.
func (r *FilesystemStacksRepository) Root() string {
	return r.root
}

// Catalog reads `.terraform-var-catalog.hcl`, when it is a file.
func (r *FilesystemStacksRepository) Catalog() (string, bool, error) {
	path := paths.Join(r.root, entities.CatalogName)
	if !paths.IsFile(path) {
		return "", false, nil
	}
	source, err := text.ReadStrict(path)
	return source, err == nil, err
}

// Stacks are the directories holding a `.tf` file below `stacks/`, the
// vendored copies under `.terraform` left out.
func (r *FilesystemStacksRepository) Stacks() []string {
	stacksDir := paths.Join(r.root, "stacks")
	if !paths.IsDir(stacksDir) {
		return nil
	}
	seen := map[string]bool{}
	var stacks []string
	for _, file := range paths.RGlob(stacksDir, "*.tf", vendored) {
		if paths.HasPart(file, vendored) {
			continue
		}
		dir := paths.Dir(file)
		if !seen[dir] {
			seen[dir] = true
			stacks = append(stacks, dir)
		}
	}
	paths.Sort(stacks)
	relative := make([]string, 0, len(stacks))
	for _, stack := range stacks {
		if rel, ok := paths.RelativeTo(stack, r.root); ok {
			relative = append(relative, rel)
		}
	}
	return relative
}

// Sources reads every `.tf` file of a stack but the generated one.
func (r *FilesystemStacksRepository) Sources(stack string) ([]string, error) {
	var sources []string
	for _, file := range paths.Glob(paths.Join(r.root, stack), "*.tf") {
		if paths.Base(file) == entities.OutputName {
			continue
		}
		source, err := text.ReadStrict(file)
		if err != nil {
			return nil, err
		}
		sources = append(sources, source)
	}
	return sources, nil
}

// Generated reads a stack's generated file, empty when it is not a file.
func (r *FilesystemStacksRepository) Generated(stack string) (string, error) {
	path := r.generated(stack)
	if !paths.IsFile(path) {
		return "", nil
	}
	return text.ReadStrict(path)
}

// WriteGenerated replaces a stack's generated file.
func (r *FilesystemStacksRepository) WriteGenerated(stack, content string) error {
	return text.Write(r.generated(stack), content)
}

// RemoveGenerated deletes a stack's generated file when it is a file.
func (r *FilesystemStacksRepository) RemoveGenerated(stack string) error {
	path := r.generated(stack)
	if !paths.IsFile(path) {
		return nil
	}
	if err := os.Remove(path); err != nil && !errors.Is(err, fs.ErrNotExist) {
		return err
	}
	return nil
}

func (r *FilesystemStacksRepository) generated(stack string) string {
	return paths.Join(paths.Join(r.root, stack), entities.OutputName)
}
