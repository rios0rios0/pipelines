package repositories

import "github.com/rios0rios0/pipelines/global/scripts/tools/dependency-updates/internal/domain/entities"

// ReleasesRepository answers what an upstream has published.
type ReleasesRepository interface {
	// Latest is upstream's newest release for the task -- or, for an image, the
	// digest its tag resolves to now -- before any bound is applied.
	Latest(task *entities.Task) (string, error)
	// List is the releases the task could move to, with publication dates.
	List(task *entities.Task) ([]entities.Release, error)
}
