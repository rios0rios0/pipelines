package entities_test

import (
	"testing"

	"github.com/stretchr/testify/assert"

	"github.com/rios0rios0/pipelines/global/scripts/tools/dependency-updates/internal/domain/entities"
)

func actionPackage(name string) entities.Package {
	return entities.Package{Ecosystem: entities.EcosystemGitHubActions, Name: name}
}

// tjActionsCompromise is GHSA-mrrh-fwg8-r2c3 (CVE-2025-30066) as OSV publishes
// it: a range and NO version list, which is why OSV answers "no
// vulnerabilities" when asked about v45.0.7 by version.
func tjActionsCompromise() entities.Advisory {
	return entities.Advisory{
		ID: "GHSA-mrrh-fwg8-r2c3", Aliases: []string{"CVE-2025-30066"}, Severity: "HIGH",
		Affected: []entities.AffectedPackage{{
			Package: actionPackage("tj-actions/changed-files"),
			Ranges: []entities.AffectedRange{{Type: entities.RangeEcosystem, Events: []entities.RangeEvent{
				{Introduced: "0"}, {Fixed: "46.0.1"},
			}}},
			LastKnownAffected: "<= 45.0.7",
		}},
	}
}

// codeqlPATLeak is GHSA-vqf5-2xx6-9wfm as OSV publishes it. Its v2-line entry
// is `introduced 2.26.11` with NO closing event -- the GHSA bound `< 3.0.0`
// lives only in `last_known_affected_version_range` -- which once flagged
// github/codeql-action v4.38.3 as vulnerable.
func codeqlPATLeak() entities.Advisory {
	return entities.Advisory{
		ID: "GHSA-vqf5-2xx6-9wfm", Aliases: []string{"CVE-2025-24362"}, Severity: "HIGH",
		Affected: []entities.AffectedPackage{
			{
				Package: actionPackage("github/codeql-action"),
				Ranges: []entities.AffectedRange{{Type: entities.RangeEcosystem, Events: []entities.RangeEvent{
					{Introduced: "3.26.11"}, {Fixed: "3.28.3"},
				}}},
				LastKnownAffected: "<= 3.28.2",
			},
			{
				Package: actionPackage("github/codeql-action"),
				Ranges: []entities.AffectedRange{{Type: entities.RangeEcosystem, Events: []entities.RangeEvent{
					{Introduced: "2.26.11"},
				}}},
				LastKnownAffected: "< 3.0.0",
			},
		},
	}
}

func TestAdvisoryAffects(t *testing.T) {
	t.Parallel()

	t.Run("should affect the compromised action version when only a range is published", func(t *testing.T) {
		t.Parallel()
		// given
		advisory := tjActionsCompromise()

		// when
		affected := advisory.Affects(actionPackage("tj-actions/changed-files"), "v45.0.7")

		// then
		assert.True(t, affected)
	})

	t.Run("should not affect the release that fixes it", func(t *testing.T) {
		t.Parallel()
		// given
		advisory := tjActionsCompromise()

		// when
		affected := advisory.Affects(actionPackage("tj-actions/changed-files"), "v46.0.1")

		// then
		assert.False(t, affected)
	})

	t.Run("should not affect a later major when GHSA bounded an open-ended range", func(t *testing.T) {
		t.Parallel()
		// given
		advisory := codeqlPATLeak()

		// when
		affected := advisory.Affects(actionPackage("github/codeql-action"), "v4.38.3")

		// then
		assert.False(t, affected, "GHSA's `< 3.0.0` must bound the v2 line's open range")
	})

	t.Run("should affect every line the advisory names inside its bounds", func(t *testing.T) {
		t.Parallel()
		// given
		advisory := codeqlPATLeak()

		// when
		inTwo := advisory.Affects(actionPackage("github/codeql-action"), "v2.26.12")
		inThree := advisory.Affects(actionPackage("github/codeql-action"), "v3.28.2")
		fixed := advisory.Affects(actionPackage("github/codeql-action"), "v3.28.3")

		// then
		assert.True(t, inTwo)
		assert.True(t, inThree)
		assert.False(t, fixed)
	})

	t.Run("should affect a sub-path action through its repository", func(t *testing.T) {
		t.Parallel()
		// given
		advisory := tjActionsCompromise()
		advisory.Affected[0].Package.Name = "tj-actions/changed-files/sub"

		// when
		affected := advisory.Affects(actionPackage("tj-actions/changed-files"), "v45.0.0")

		// then
		assert.True(t, affected)
	})

	t.Run("should affect an explicitly listed version", func(t *testing.T) {
		t.Parallel()
		// given
		advisory := entities.Advisory{ID: "MAL-2025-46969", Affected: []entities.AffectedPackage{{
			Package: entities.Package{Ecosystem: entities.EcosystemNpm, Name: "chalk"}, Versions: []string{"5.6.1"},
		}}}

		// when
		listed := advisory.Affects(entities.Package{Ecosystem: entities.EcosystemNpm, Name: "chalk"}, "5.6.1")
		other := advisory.Affects(entities.Package{Ecosystem: entities.EcosystemNpm, Name: "chalk"}, "5.6.2")

		// then
		assert.True(t, listed)
		assert.False(t, other)
	})

	t.Run("should never apply to another package", func(t *testing.T) {
		t.Parallel()
		// given
		advisory := tjActionsCompromise()

		// when
		affected := advisory.Affects(actionPackage("tj-actions/other"), "v1.0.0")

		// then
		assert.False(t, affected)
	})
}

func TestAdvisoryIsMalicious(t *testing.T) {
	t.Parallel()

	t.Run("should recognise an OpenSSF malicious-package record", func(t *testing.T) {
		t.Parallel()
		// given
		advisory := entities.Advisory{ID: "MAL-2025-46974"}

		// when
		malicious := advisory.IsMalicious()

		// then
		assert.True(t, malicious)
		assert.Equal(t, entities.SeverityMalicious, advisory.DisplaySeverity())
	})

	t.Run("should recognise a GHSA that cross-references one", func(t *testing.T) {
		t.Parallel()
		// given
		advisory := entities.Advisory{ID: "GHSA-4x49-vf9v-38px", Aliases: []string{"CVE-2025-59144", "MAL-2025-46974"}}

		// when
		malicious := advisory.IsMalicious()

		// then
		assert.True(t, malicious)
	})

	t.Run("should recognise a GHSA classified as embedded malicious code", func(t *testing.T) {
		t.Parallel()
		// given
		advisory := entities.Advisory{ID: "GHSA-x", CWEs: []string{"CWE-506"}}

		// when
		malicious := advisory.IsMalicious()

		// then
		assert.True(t, malicious)
	})

	t.Run("should not call an ordinary vulnerability malicious", func(t *testing.T) {
		t.Parallel()
		// given
		advisory := tjActionsCompromise()

		// when
		malicious := advisory.IsMalicious()

		// then
		assert.False(t, malicious)
		assert.Equal(t, "HIGH", advisory.DisplaySeverity())
	})
}

func TestUnaccepted(t *testing.T) {
	t.Parallel()

	t.Run("should drop an advisory accepted until a date that has not passed", func(t *testing.T) {
		t.Parallel()
		// given
		advisories := []entities.Advisory{tjActionsCompromise()}
		acceptances := []entities.Acceptance{{ID: "CVE-2025-30066", Reason: "not reachable", Until: "2026-12-31"}}

		// when
		remaining := entities.Unaccepted(advisories, acceptances, "2026-10-10")

		// then
		assert.Empty(t, remaining)
	})

	t.Run("should keep an advisory whose acceptance has expired", func(t *testing.T) {
		t.Parallel()
		// given
		advisories := []entities.Advisory{tjActionsCompromise()}
		acceptances := []entities.Acceptance{{ID: "GHSA-mrrh-fwg8-r2c3", Reason: "not reachable", Until: "2026-01-01"}}

		// when
		remaining := entities.Unaccepted(advisories, acceptances, "2026-10-10")

		// then
		assert.Len(t, remaining, 1)
	})

	t.Run("should never accept a malicious package", func(t *testing.T) {
		t.Parallel()
		// given
		advisories := []entities.Advisory{{ID: "MAL-2025-46969"}}
		acceptances := []entities.Acceptance{{ID: "MAL-2025-46969", Reason: "trust me", Until: "2099-01-01"}}

		// when
		remaining := entities.Unaccepted(advisories, acceptances, "2026-10-10")

		// then
		assert.Len(t, remaining, 1)
	})
}

func TestIntroducedAndResolved(t *testing.T) {
	t.Parallel()

	t.Run("should count an issue published under another identifier as the same one", func(t *testing.T) {
		t.Parallel()
		// given
		current := []entities.Advisory{{ID: "GO-2026-1", Aliases: []string{"CVE-2026-1"}}}
		proposed := []entities.Advisory{{ID: "GHSA-a", Aliases: []string{"CVE-2026-1"}}, {ID: "GHSA-new"}}

		// when
		introduced := entities.Introduced(current, proposed)
		resolved := entities.Resolved(current, proposed)

		// then
		assert.Equal(t, []string{"GHSA-new"}, entities.AdvisoryIDs(introduced))
		assert.Empty(t, resolved)
	})

	t.Run("should report what a move fixes", func(t *testing.T) {
		t.Parallel()
		// given
		current := []entities.Advisory{{ID: "GHSA-old"}}

		// when
		resolved := entities.Resolved(current, nil)

		// then
		assert.Equal(t, []string{"GHSA-old"}, entities.AdvisoryIDs(resolved))
	})
}

func TestSecurityStatusAnswer(t *testing.T) {
	t.Parallel()

	t.Run("should ask about every package and count an issue filed under two of them once", func(t *testing.T) {
		t.Parallel()
		// given
		stdlib := entities.Package{Ecosystem: entities.EcosystemGo, Name: "stdlib"}
		toolchain := entities.Package{Ecosystem: entities.EcosystemGo, Name: "toolchain"}
		status := entities.SecurityStatus{Packages: []entities.Package{stdlib, toolchain}}
		shared := entities.Advisory{ID: "GO-2026-3"}
		found := map[entities.AdvisoryQuery][]entities.Advisory{
			{Package: stdlib, Version: "1.27.1"}:    {{ID: "GO-2026-1"}, shared},
			{Package: toolchain, Version: "1.27.1"}: {{ID: "GO-2026-2"}, shared},
		}

		// when
		queries, answer := status.Queries("1.27.1"), status.Answer(found, "1.27.1")

		// then
		assert.Len(t, queries, 2)
		assert.Equal(t, []string{"GO-2026-1", "GO-2026-3", "GO-2026-2"}, entities.AdvisoryIDs(answer))
	})
}
