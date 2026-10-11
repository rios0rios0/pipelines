package repositories

import "github.com/rios0rios0/pipelines/global/scripts/tools/dependency-updates/internal/domain/entities"

// SourceRepository answers questions about an action's git history.
type SourceRepository interface {
	// TagCommit is the commit a tag points at, an annotated tag dereferenced.
	TagCommit(repository, tag string) (string, error)
	// Compare relates two commits of one repository.
	Compare(repository, base, head string) (entities.Comparison, error)
}
