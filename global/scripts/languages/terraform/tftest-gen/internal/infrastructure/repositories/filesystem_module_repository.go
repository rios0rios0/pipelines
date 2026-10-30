// Package repositories holds the adapters the smoke-test generator reaches a
// module and `terraform fmt` through.
package repositories

import (
	"errors"
	"io/fs"
	"os"

	"github.com/rios0rios0/pipelines/global/scripts/languages/terraform/internal/paths"
	"github.com/rios0rios0/pipelines/global/scripts/languages/terraform/internal/text"
)

// FilesystemModuleRepository is a module checked out on disk.
type FilesystemModuleRepository struct {
	root string
}

// NewFilesystemModuleRepository opens the module at `root`, already resolved.
func NewFilesystemModuleRepository(root string) *FilesystemModuleRepository {
	return &FilesystemModuleRepository{root: root}
}

// Source reads a root file, empty when nothing exists by that name.
func (r *FilesystemModuleRepository) Source(name string) (string, error) {
	path := paths.Join(r.root, name)
	if !paths.Exists(path) {
		return "", nil
	}
	return text.ReadStrict(path)
}

// SmokeTest reads the existing test, when anything exists at its path.
func (r *FilesystemModuleRepository) SmokeTest() (string, bool, error) {
	path := r.SmokeTestPath()
	if !paths.Exists(path) {
		return "", false, nil
	}
	existing, err := text.ReadStrict(path)
	return existing, err == nil, err
}

// WriteSmokeTest writes the test, creating `tests/` -- but not the module --
// when it is missing.
func (r *FilesystemModuleRepository) WriteSmokeTest(content string) error {
	err := os.Mkdir(paths.Join(r.root, "tests"), text.NewDirMode)
	if err != nil && !errors.Is(err, fs.ErrExist) {
		return err
	}
	return text.Write(r.SmokeTestPath(), content)
}

// SmokeTestPath is `<root>/tests/smoke.tftest.hcl`.
func (r *FilesystemModuleRepository) SmokeTestPath() string {
	return paths.Join(paths.Join(r.root, "tests"), "smoke.tftest.hcl")
}
