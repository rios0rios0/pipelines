// Package entities holds what a license id is to the SPDX license list a CycloneDX schema
// validates against, and how a BOM's license ids are made ones that list holds.
package entities

import "strings"

// DeprecatedPrefix is how SPDX's license-list-data names the text of a DEPRECATED license id:
// `text/deprecated_GPL-2.0+.txt` is the text of `GPL-2.0+`. go-license-detector names the licenses
// it matches after those files, and cyclonedx-gomod writes the detector's name as `license.id`
// verbatim, so a module whose license reads as a deprecated id gets `deprecated_GPL-2.0+` -- an id
// no SPDX license list has ever held, and one Dependency-Track's schema validation refuses.
const DeprecatedPrefix = "deprecated_"

// Verdict is what a license id is to the SPDX license list.
type Verdict int

const (
	// VerdictListed is an id the list holds. It stays as written.
	VerdictListed Verdict = iota
	// VerdictRestored is `deprecated_<id>` whose `<id>` the list holds: the SPDX id under the name
	// of its license-list file. `<id>` is written instead, which loses nothing -- the list itself
	// marks that id deprecated.
	VerdictRestored
	// VerdictNamed is an id the list does not hold. It is written as the license's `name`, which
	// keeps it in the BOM and which every schema version accepts as any string.
	VerdictNamed
)

// Resolution is the verdict on one license id, with the text the BOM keeps.
type Resolution struct {
	Verdict Verdict
	// ID is the id written: the one the list holds for VerdictListed and VerdictRestored, the id
	// as the generator wrote it -- now the license's name -- for VerdictNamed.
	ID string
}

// LicenseList is the set of SPDX license ids a CycloneDX `license.id` may hold.
type LicenseList struct {
	version string
	ids     map[string]struct{}
}

// NewLicenseList builds the list from its version label and its ids.
func NewLicenseList(version string, ids []string) LicenseList {
	set := make(map[string]struct{}, len(ids))
	for _, id := range ids {
		set[id] = struct{}{}
	}
	return LicenseList{version: version, ids: set}
}

// Version is the list's version label, e.g. `v1.0-3.27.0`: every id from SPDX license list 1.0
// to 3.27.0.
func (l LicenseList) Version() string {
	return l.version
}

// Len is how many ids the list holds.
func (l LicenseList) Len() int {
	return len(l.ids)
}

// Holds reports whether the list holds `id` exactly as written. The schema's enumeration is
// case-sensitive, so `mit` is not `MIT`.
func (l LicenseList) Holds(id string) bool {
	_, found := l.ids[id]
	return found
}

// Resolve gives the verdict on `id`.
func (l LicenseList) Resolve(id string) Resolution {
	if l.Holds(id) {
		return Resolution{Verdict: VerdictListed, ID: id}
	}
	if listed, found := strings.CutPrefix(id, DeprecatedPrefix); found && l.Holds(listed) {
		return Resolution{Verdict: VerdictRestored, ID: listed}
	}
	return Resolution{Verdict: VerdictNamed, ID: id}
}
