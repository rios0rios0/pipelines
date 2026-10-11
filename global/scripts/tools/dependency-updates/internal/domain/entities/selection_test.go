package entities_test

import (
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/rios0rios0/pipelines/global/scripts/tools/dependency-updates/internal/domain/entities"
)

func referenceNow() time.Time {
	return time.Date(2026, 10, 10, 6, 0, 0, 0, time.UTC)
}

func daysAgo(days int) time.Time {
	return referenceNow().Add(-time.Duration(days) * entities.Day)
}

func candidate(version string, published time.Time, advisories ...entities.Advisory) entities.Candidate {
	return entities.Candidate{Release: entities.Release{Version: version, Published: published}, Advisories: advisories}
}

func policy() entities.SelectionPolicy {
	return entities.SelectionPolicy{Now: referenceNow(), Cooldown: entities.DefaultCooldown}
}

func TestSelectionPolicySelect(t *testing.T) {
	t.Parallel()

	t.Run("should propose the newest release past the cooldown", func(t *testing.T) {
		t.Parallel()
		// given
		candidates := []entities.Candidate{candidate("1.3.0", daysAgo(10)), candidate("1.2.9", daysAgo(30))}

		// when
		selection := policy().Select(nil, candidates)

		// then
		require.NotNil(t, selection.Target)
		assert.Equal(t, "1.3.0", selection.Target.Version)
		assert.False(t, selection.Waived)
	})

	t.Run("should hold a release younger than the cooldown and propose an older one", func(t *testing.T) {
		t.Parallel()
		// given
		candidates := []entities.Candidate{candidate("1.4.0", daysAgo(2)), candidate("1.3.0", daysAgo(10))}

		// when
		selection := policy().Select(nil, candidates)

		// then
		require.NotNil(t, selection.Target)
		assert.Equal(t, "1.3.0", selection.Target.Version)
		require.NotNil(t, selection.Held)
		assert.Equal(t, "1.4.0", selection.Held.Version)
	})

	t.Run("should propose nothing when every newer release is too young", func(t *testing.T) {
		t.Parallel()
		// given
		candidates := []entities.Candidate{candidate("1.4.0", daysAgo(1))}

		// when
		selection := policy().Select(nil, candidates)

		// then
		assert.Nil(t, selection.Target)
		require.NotNil(t, selection.Held)
	})

	t.Run("should never satisfy the cooldown with an unknown publication date", func(t *testing.T) {
		t.Parallel()
		// given
		candidates := []entities.Candidate{candidate("1.4.0", time.Time{})}

		// when
		selection := policy().Select(nil, candidates)

		// then
		assert.Nil(t, selection.Target)
	})

	t.Run("should skip a release that introduces an advisory for an older safe one", func(t *testing.T) {
		t.Parallel()
		// given
		bad := entities.Advisory{ID: "GHSA-new", Severity: "CRITICAL"}
		candidates := []entities.Candidate{candidate("2.0.0", daysAgo(20), bad), candidate("1.9.0", daysAgo(40))}

		// when
		selection := policy().Select(nil, candidates)

		// then
		require.NotNil(t, selection.Target)
		assert.Equal(t, "1.9.0", selection.Target.Version)
		require.Len(t, selection.Rejected, 1)
		assert.Contains(t, selection.Rejected[0].Reason, "would introduce GHSA-new")
	})

	t.Run("should never propose a known malicious release", func(t *testing.T) {
		t.Parallel()
		// given
		malware := entities.Advisory{ID: "MAL-2025-46969"}
		candidates := []entities.Candidate{candidate("5.6.1", daysAgo(400), malware)}

		// when
		selection := policy().Select(nil, candidates)

		// then
		assert.Nil(t, selection.Target)
		require.Len(t, selection.Rejected, 1)
		assert.Contains(t, selection.Rejected[0].Reason, "known malicious release")
	})

	t.Run("should not count an advisory the pin already has as introduced", func(t *testing.T) {
		t.Parallel()
		// given
		existing := entities.Advisory{ID: "GHSA-old"}
		candidates := []entities.Candidate{candidate("1.1.0", daysAgo(20), existing)}

		// when
		selection := policy().Select([]entities.Advisory{existing}, candidates)

		// then
		require.NotNil(t, selection.Target)
		assert.Equal(t, []string{"GHSA-old"}, entities.AdvisoryIDs(selection.Remaining))
		assert.Empty(t, selection.Fixed)
	})

	t.Run("should prefer an aged release that fixes the pin's advisories", func(t *testing.T) {
		t.Parallel()
		// given
		known := entities.Advisory{ID: "GHSA-known"}
		candidates := []entities.Candidate{candidate("1.3.0", daysAgo(1)), candidate("1.2.0", daysAgo(9))}

		// when
		selection := policy().Select([]entities.Advisory{known}, candidates)

		// then
		require.NotNil(t, selection.Target)
		assert.Equal(t, "1.2.0", selection.Target.Version)
		assert.False(t, selection.Waived)
		assert.Equal(t, []string{"GHSA-known"}, entities.AdvisoryIDs(selection.Fixed))
	})

	t.Run("should waive the cooldown for the oldest fix when no aged release fixes the pin", func(t *testing.T) {
		t.Parallel()
		// given
		known := entities.Advisory{ID: "GHSA-known"}
		candidates := []entities.Candidate{
			candidate("1.3.0", daysAgo(1)), candidate("1.2.1", daysAgo(3)), candidate("1.2.0", daysAgo(20), known),
		}

		// when
		selection := policy().Select([]entities.Advisory{known}, candidates)

		// then
		require.NotNil(t, selection.Target)
		assert.Equal(
			t,
			"1.2.1",
			selection.Target.Version,
			"the oldest unaged fix has had the longest to be scrutinised",
		)
		assert.True(t, selection.Waived)
		assert.Empty(t, selection.Remaining)
	})

	t.Run("should leave a vulnerability in place when no release fixes it", func(t *testing.T) {
		t.Parallel()
		// given
		known := entities.Advisory{ID: "GHSA-known"}
		candidates := []entities.Candidate{candidate("1.1.0", daysAgo(20), known)}

		// when
		selection := policy().Select([]entities.Advisory{known}, candidates)

		// then
		require.NotNil(t, selection.Target)
		assert.Equal(t, []string{"GHSA-known"}, entities.AdvisoryIDs(selection.Remaining))
	})

	t.Run("should never waive the cooldown for a fix that introduces another advisory", func(t *testing.T) {
		t.Parallel()
		// given
		known := entities.Advisory{ID: "GHSA-known"}
		other := entities.Advisory{ID: "GHSA-other"}
		candidates := []entities.Candidate{candidate("1.2.0", daysAgo(1), other)}

		// when
		selection := policy().Select([]entities.Advisory{known}, candidates)

		// then
		assert.Nil(t, selection.Target)
		assert.Equal(t, []string{"GHSA-known"}, entities.AdvisoryIDs(selection.Remaining))
	})

	t.Run("should take any release when the cooldown is zero", func(t *testing.T) {
		t.Parallel()
		// given
		zero := entities.SelectionPolicy{Now: referenceNow()}
		candidates := []entities.Candidate{candidate("2.0.0", time.Time{})}

		// when
		selection := zero.Select(nil, candidates)

		// then
		require.NotNil(t, selection.Target)
		assert.Equal(t, "2.0.0", selection.Target.Version)
	})
}

func TestSelectionPolicyEligibleOn(t *testing.T) {
	t.Parallel()

	t.Run("should be the publication date plus the cooldown", func(t *testing.T) {
		t.Parallel()
		// given
		release := entities.Release{Version: "1.0.0", Published: daysAgo(2)}

		// when
		eligible := policy().EligibleOn(release)

		// then
		assert.Equal(t, daysAgo(2).Add(entities.DefaultCooldown), eligible)
	})

	t.Run("should be unknown when the publication date is", func(t *testing.T) {
		t.Parallel()
		// given
		release := entities.Release{Version: "1.0.0"}

		// when
		eligible := policy().EligibleOn(release)

		// then
		assert.True(t, eligible.IsZero())
	})
}
