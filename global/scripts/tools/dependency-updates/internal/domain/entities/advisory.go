package entities

import (
	"regexp"
	"slices"
	"strings"
)

// Ecosystem names as OSV spells them.
const (
	EcosystemGitHubActions = "GitHub Actions"
	EcosystemPyPI          = "PyPI"
	EcosystemNpm           = "npm"
	EcosystemRubyGems      = "RubyGems"
	EcosystemGo            = "Go"
)

// Range types an advisory's affected ranges are written in.
const (
	RangeSemver    = "SEMVER"
	RangeEcosystem = "ECOSYSTEM"
)

// SeverityMalicious is shown for an advisory that reports malicious code rather
// than a defect. It outranks every CVSS rating: there is nothing to weigh.
const SeverityMalicious = "MALICIOUS"

// cweEmbeddedMaliciousCode is how GHSA classifies a malware advisory.
const cweEmbeddedMaliciousCode = "CWE-506"

// Package is a dependency's identity in an advisory database.
type Package struct {
	Ecosystem string
	Name      string
}

// RangeEvent is one OSV range event; exactly one field is set.
type RangeEvent struct {
	Introduced   string
	Fixed        string
	LastAffected string
}

// AffectedRange is one OSV range: events in version order.
type AffectedRange struct {
	Type   string
	Events []RangeEvent
}

// AffectedPackage is the part of an advisory that names one package.
type AffectedPackage struct {
	Package  Package
	Versions []string
	Ranges   []AffectedRange
	// LastKnownAffected is GHSA's own upper bound (`< 3.0.0`, `<= 3.28.2`),
	// which OSV keeps beside the ranges rather than in them when the release
	// line it closes has no fixed version. Without it, `introduced 2.26.11`
	// reads as "every release from 2.26.11 on": GHSA-vqf5-2xx6-9wfm, a v2-line
	// advisory against github/codeql-action, then flagged v4.38.3.
	LastKnownAffected string
}

// Advisory is one known vulnerability or malicious-package report.
type Advisory struct {
	ID        string
	Aliases   []string
	Summary   string
	Severity  string
	CWEs      []string
	Withdrawn bool
	Affected  []AffectedPackage
}

// IsMalicious is true for a report of malicious code: an OpenSSF `MAL-` record,
// a GHSA cross-referencing one, or one classified CWE-506. The September 2025
// npm compromise (chalk 5.6.1, debug 4.4.2) is published both ways, and a check
// reading only one of them would wave the other through.
func (a Advisory) IsMalicious() bool {
	if strings.HasPrefix(a.ID, "MAL-") || slices.Contains(a.CWEs, cweEmbeddedMaliciousCode) {
		return true
	}
	return slices.ContainsFunc(a.Aliases, func(alias string) bool { return strings.HasPrefix(alias, "MAL-") })
}

// DisplaySeverity is the severity a person reads in a report.
func (a Advisory) DisplaySeverity() string {
	if a.IsMalicious() {
		return SeverityMalicious
	}
	if a.Severity == "" {
		return "UNRATED"
	}
	return strings.ToUpper(a.Severity)
}

// Names are the advisory's ID and every alias, for matching the same issue
// published under several identifiers (`GHSA-...`, `CVE-...`, `GO-...`).
func (a Advisory) Names() []string {
	return append([]string{a.ID}, a.Aliases...)
}

// SameIssue is true when two advisories describe one vulnerability.
func (a Advisory) SameIssue(other Advisory) bool {
	names := other.Names()
	return slices.ContainsFunc(a.Names(), func(name string) bool { return slices.Contains(names, name) })
}

// Affects evaluates the advisory's ranges for one version, the way OSV does.
//
// OSV evaluates versions server-side for most ecosystems, but NOT for GitHub
// Actions: the record of the tj-actions/changed-files compromise
// (GHSA-mrrh-fwg8-r2c3) carries `introduced 0`, `fixed 46.0.1` and an empty
// version list, so asking OSV about v45.0.7 answers "no vulnerabilities". The
// ranges are evaluated here instead, by the algorithm the OSV schema defines.
func (a Advisory) Affects(pkg Package, version string) bool {
	for _, affected := range a.Affected {
		if !samePackage(affected.Package, pkg) {
			continue
		}
		if affected.covers(version) {
			return true
		}
	}
	return false
}

func samePackage(advised, pinned Package) bool {
	if !strings.EqualFold(advised.Ecosystem, pinned.Ecosystem) {
		return false
	}
	if strings.EqualFold(advised.Name, pinned.Name) {
		return true
	}
	// An advisory may name a sub-path action (`owner/repo/init`); the pin is
	// the whole repository, so it is affected too.
	return pinned.Ecosystem == EcosystemGitHubActions &&
		strings.HasPrefix(strings.ToLower(advised.Name), strings.ToLower(pinned.Name)+"/")
}

func (p AffectedPackage) covers(version string) bool {
	normalised := Normalise(version)
	if slices.ContainsFunc(p.Versions, func(listed string) bool { return Normalise(listed) == normalised }) {
		return true
	}
	if !satisfies(version, p.LastKnownAffected) {
		return false
	}
	for _, affectedRange := range p.Ranges {
		if (affectedRange.Type == RangeSemver || affectedRange.Type == RangeEcosystem) &&
			affectedRange.covers(version) {
			return true
		}
	}
	return false
}

// boundPattern is one comparator of a GHSA range expression.
var boundPattern = regexp.MustCompile(`^(<=|>=|<|>|=)\s*(\S+)$`)

// satisfies is true when `version` meets every comma-separated comparator of a
// GHSA range expression (`>= 2.0, < 3.0.0`); an empty expression bounds
// nothing. An expression that cannot be read bounds nothing either: an
// advisory that cannot be narrowed must not read as one that does not apply.
func satisfies(version, expression string) bool {
	for comparator := range strings.SplitSeq(expression, ",") {
		comparator = strings.TrimSpace(comparator)
		if comparator == "" {
			continue
		}
		match := boundPattern.FindStringSubmatch(comparator)
		if match == nil {
			return true
		}
		order := CompareVersions(version, match[2])
		if !comparatorHolds(match[1], order) {
			return false
		}
	}
	return true
}

func comparatorHolds(operator string, order int) bool {
	switch operator {
	case "<":
		return order < 0
	case "<=":
		return order <= 0
	case ">":
		return order > 0
	case ">=":
		return order >= 0
	default:
		return order == 0
	}
}

// covers walks the events in version order: `introduced` switches the range on,
// `fixed` (at or below the version) and `last_affected` (below it) switch it off.
// A version that cannot be ordered is treated as affected -- an advisory that
// cannot be evaluated must not read as one that does not apply.
func (r AffectedRange) covers(version string) bool {
	if len(Parts(version)) == 0 {
		return true
	}
	events := slices.Clone(r.Events)
	slices.SortStableFunc(events, func(left, right RangeEvent) int {
		return CompareVersions(left.version(), right.version())
	})
	affected := false
	for _, event := range events {
		switch {
		case event.Introduced != "":
			if event.Introduced == "0" || CompareVersions(version, event.Introduced) >= 0 {
				affected = true
			}
		case event.Fixed != "":
			if CompareVersions(version, event.Fixed) >= 0 {
				affected = false
			}
		case event.LastAffected != "":
			if CompareVersions(version, event.LastAffected) > 0 {
				affected = false
			}
		}
	}
	return affected
}

func (e RangeEvent) version() string {
	switch {
	case e.Introduced != "":
		return e.Introduced
	case e.Fixed != "":
		return e.Fixed
	default:
		return e.LastAffected
	}
}

// Acceptance is a known advisory a person has decided to live with until a
// date, with the reason recorded where review sees it.
type Acceptance struct {
	ID     string
	Reason string
	Until  string
}

// Accepts is true when an acceptance covers the advisory on `today` (an
// RFC 3339 date). A malicious package is never accepted: running known malware
// is not a risk a reason can make reasonable.
func (a Acceptance) Accepts(advisory Advisory, today string) bool {
	return !advisory.IsMalicious() && a.Until >= today && slices.Contains(advisory.Names(), a.ID)
}

// Unaccepted drops the advisories an acceptance covers today.
func Unaccepted(advisories []Advisory, acceptances []Acceptance, today string) []Advisory {
	return slices.DeleteFunc(slices.Clone(advisories), func(advisory Advisory) bool {
		return slices.ContainsFunc(acceptances, func(acceptance Acceptance) bool {
			return acceptance.Accepts(advisory, today)
		})
	})
}

// Introduced are the advisories of `proposed` that `current` does not already
// have: what moving from one to the other would bring in.
func Introduced(current, proposed []Advisory) []Advisory {
	return slices.DeleteFunc(slices.Clone(proposed), func(advisory Advisory) bool {
		return slices.ContainsFunc(current, advisory.SameIssue)
	})
}

// Resolved are the advisories of `current` that `proposed` no longer has: what
// the move fixes.
func Resolved(current, proposed []Advisory) []Advisory {
	return Introduced(proposed, current)
}

// AnyMalicious is true when one of the advisories reports malicious code.
func AnyMalicious(advisories []Advisory) bool {
	return slices.ContainsFunc(advisories, Advisory.IsMalicious)
}

// AdvisoryIDs lists the advisories' IDs, for messages.
func AdvisoryIDs(advisories []Advisory) []string {
	identifiers := make([]string, 0, len(advisories))
	for _, advisory := range advisories {
		identifiers = append(identifiers, advisory.ID)
	}
	return identifiers
}
