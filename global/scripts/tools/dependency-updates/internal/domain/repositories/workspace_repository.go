package repositories

// WorkspaceRepository is the repository being scanned, read once and edited in
// memory. Paths are relative to its root and slash-separated.
type WorkspaceRepository interface {
	Root() string
	Text(path string) string
	Set(path, text string) bool
	YAMLFiles() []string
	Dockerfiles() []string
	IsFile(path string) bool
	IsDir(path string) bool
	Changed() []string
	Write() ([]string, error)
}
