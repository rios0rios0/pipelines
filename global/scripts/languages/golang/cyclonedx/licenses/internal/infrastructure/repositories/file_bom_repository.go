package repositories

import (
	"os"
	"path/filepath"
)

// FileBOMRepository is a BOM on disk.
type FileBOMRepository struct {
	path string
}

// NewFileBOMRepository is the BOM at `path`.
func NewFileBOMRepository(path string) *FileBOMRepository {
	return &FileBOMRepository{path: filepath.Clean(path)}
}

// Read returns the file's bytes.
func (r *FileBOMRepository) Read() ([]byte, error) {
	return os.ReadFile(r.path)
}

// Write replaces the file's bytes, keeping its permissions.
func (r *FileBOMRepository) Write(document []byte) error {
	info, err := os.Stat(r.path)
	if err != nil {
		return err
	}
	return os.WriteFile(r.path, document, info.Mode().Perm())
}
