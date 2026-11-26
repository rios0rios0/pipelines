// Package doubles holds handwritten test doubles for the license normalisation's ports. No mocking
// library: each double implements its port the way a test needs it to behave.
package doubles

import (
	"errors"

	"github.com/rios0rios0/pipelines/global/scripts/languages/golang/cyclonedx/licenses/internal/domain/entities"
)

// ErrUnavailable is what a double told to fail returns.
var ErrUnavailable = errors.New("unavailable")

// InMemoryBOMRepository is a BOM held in memory, recording what was written to it.
type InMemoryBOMRepository struct {
	Document    []byte
	Writes      [][]byte
	FailOnRead  bool
	FailOnWrite bool
}

// NewInMemoryBOMRepository holds `document`.
func NewInMemoryBOMRepository(document string) *InMemoryBOMRepository {
	return &InMemoryBOMRepository{Document: []byte(document)}
}

// Read returns the BOM held, or ErrUnavailable when told to fail.
func (r *InMemoryBOMRepository) Read() ([]byte, error) {
	if r.FailOnRead {
		return nil, ErrUnavailable
	}
	return r.Document, nil
}

// Write replaces the BOM held and records the write, or returns ErrUnavailable when told to fail.
func (r *InMemoryBOMRepository) Write(document []byte) error {
	if r.FailOnWrite {
		return ErrUnavailable
	}
	r.Document = document
	r.Writes = append(r.Writes, document)
	return nil
}

// StubLicenseListRepository returns a fixed list, or ErrUnavailable when told to fail.
type StubLicenseListRepository struct {
	List entities.LicenseList
	Fail bool
}

// NewStubLicenseListRepository returns a list labelled `version` holding `ids`.
func NewStubLicenseListRepository(version string, ids ...string) *StubLicenseListRepository {
	return &StubLicenseListRepository{List: entities.NewLicenseList(version, ids)}
}

// Load returns the list.
func (r *StubLicenseListRepository) Load() (entities.LicenseList, error) {
	if r.Fail {
		return entities.LicenseList{}, ErrUnavailable
	}
	return r.List, nil
}
