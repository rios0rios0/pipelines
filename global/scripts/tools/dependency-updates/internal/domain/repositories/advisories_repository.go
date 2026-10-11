package repositories

import "github.com/rios0rios0/pipelines/global/scripts/tools/dependency-updates/internal/domain/entities"

// AdvisoriesRepository finds known vulnerabilities and malicious-package
// reports.
type AdvisoriesRepository interface {
	// FindAll returns, for each query, the advisories affecting that version.
	// A query whose package the database does not know answers with none.
	FindAll(queries []entities.AdvisoryQuery) (map[entities.AdvisoryQuery][]entities.Advisory, error)
}
