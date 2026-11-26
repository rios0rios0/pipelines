// Package repositories holds the ports the license normalisation reads and writes through.
package repositories

import "github.com/rios0rios0/pipelines/global/scripts/languages/golang/cyclonedx/licenses/internal/domain/entities"

// BOMRepository is the BOM being normalised.
type BOMRepository interface {
	// Read returns the BOM as written.
	Read() ([]byte, error)
	// Write replaces the BOM with `document`.
	Write(document []byte) error
}

// LicenseListRepository is the SPDX license list the ids are checked against.
type LicenseListRepository interface {
	// Load returns the list.
	Load() (entities.LicenseList, error)
}
