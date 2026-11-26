// Package repositories holds the adapters of the license normalisation's ports: the BOM on disk
// and the SPDX license list this checkout carries.
package repositories

import (
	_ "embed" // the SPDX license list is the CycloneDX schema file itself, embedded verbatim
	"encoding/json"
	"errors"
	"fmt"

	"github.com/rios0rios0/pipelines/global/scripts/languages/golang/cyclonedx/licenses/internal/domain/entities"
)

// spdxSchema is CycloneDX's `schema/spdx.schema.json` at commit
// f33fae5e868cf1b79cfb9e8a9a8537087be5b1b7 of github.com/CycloneDX/specification ("Updating SPDX
// license list to 3.27.0"), byte for byte: SHA-256
// 54a6288292bc6c90b0d3952f5f939f17436fa76704ffe68a46e5b78539c7cc1b, `$comment` `v1.0-3.27.0`.
//
// It is the enumeration Dependency-Track validates a `license.id` against: cyclonedx-core-java
// 11.0.1 and 12.1.0 bundle exactly this file, and they are the validators of Dependency-Track
// 4.13.6, 4.14.0 to 4.14.3 and 5.0.0 to 5.0.5. The later releases bundle a newer list that holds
// every id this one does (3.28.0 in cyclonedx-core-java 13.2.0, 3.29.0 in 13.4.0). So it is pinned
// to the OLDEST list a server in use validates against, never to the newest: an id only a newer
// list holds would pass here and still be refused by a 5.0.5 server. Moving it is a decision about
// which servers the pipeline still uploads to, not a routine bump.
//
//go:embed spdx.schema.json
var spdxSchema []byte

// ErrEmptyLicenseList is a schema file that enumerates no license id.
var ErrEmptyLicenseList = errors.New("the SPDX schema enumerates no license id")

// EmbeddedLicenseListRepository is the SPDX license list this checkout carries.
type EmbeddedLicenseListRepository struct{}

// NewEmbeddedLicenseListRepository returns the repository.
func NewEmbeddedLicenseListRepository() *EmbeddedLicenseListRepository {
	return &EmbeddedLicenseListRepository{}
}

// Load parses the embedded schema file.
func (r *EmbeddedLicenseListRepository) Load() (entities.LicenseList, error) {
	return ParseLicenseList(spdxSchema)
}

// ParseLicenseList reads a CycloneDX `spdx.schema.json`: its `enum` is the list, its `$comment`
// the list's version label.
func ParseLicenseList(schema []byte) (entities.LicenseList, error) {
	var document struct {
		Comment string   `json:"$comment"`
		IDs     []string `json:"enum"`
	}
	if err := json.Unmarshal(schema, &document); err != nil {
		return entities.LicenseList{}, fmt.Errorf("could not read the SPDX schema: %w", err)
	}
	if len(document.IDs) == 0 {
		return entities.LicenseList{}, ErrEmptyLicenseList
	}
	return entities.NewLicenseList(document.Comment, document.IDs), nil
}
