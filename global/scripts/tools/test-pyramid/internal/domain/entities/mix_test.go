package entities_test

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/rios0rios0/pipelines/global/scripts/tools/test-pyramid/internal/domain/entities"
)

func TestMix(t *testing.T) {
	t.Parallel()

	t.Run("should default to Software Engineering at Google's 80/15/5", func(t *testing.T) {
		t.Parallel()
		// given
		mix := entities.DefaultMix()

		// when
		written := mix.String()

		// then
		assert.Equal(t, "80/15/5", written)
		assert.Equal(t, 20, mix.Limit(entities.TierIntegration))
		assert.Equal(t, 5, mix.Limit(entities.TierFunctional))
		assert.Equal(t, 5, mix.Limit(entities.TierE2E))
	})

	t.Run("should round an allowance up to a whole test case", func(t *testing.T) {
		t.Parallel()
		// given
		mix := entities.DefaultMix()

		// when
		allowances := []int{
			mix.Allowance(entities.TierFunctional, 1),
			mix.Allowance(entities.TierFunctional, 100),
			mix.Allowance(entities.TierFunctional, 101),
			mix.Allowance(entities.TierIntegration, 4),
		}

		// then
		assert.Equal(t, []int{1, 5, 6, 1}, allowances)
	})

	t.Run("should accept shares that add up to 100", func(t *testing.T) {
		t.Parallel()
		// given
		unit, integration, large := 70, 20, 10

		// when
		mix, err := entities.NewMix(unit, integration, large)

		// then
		require.NoError(t, err)
		assert.Equal(t, "70/20/10", mix.String())
	})

	t.Run("should refuse shares that do not add up to 100", func(t *testing.T) {
		t.Parallel()
		// given
		unit, integration, large := 70, 20, 20

		// when
		_, err := entities.NewMix(unit, integration, large)

		// then
		require.EqualError(t, err, "the mix percentages 70/20/20 do not add up to 100")
	})

	t.Run("should write an unjudged mix as off", func(t *testing.T) {
		t.Parallel()
		// given
		mix := entities.Mix{}

		// when
		written := mix.String()

		// then
		assert.Equal(t, "off", written)
	})
}

func TestCounts(t *testing.T) {
	t.Parallel()

	t.Run("should leave ignored test cases out of the total", func(t *testing.T) {
		t.Parallel()
		// given
		suite := entities.Counts{entities.TierUnit: 3, entities.TierE2E: 1, entities.TierIgnored: 9}

		// when
		total := suite.Total()

		// then
		assert.Equal(t, 4, total)
	})

	t.Run("should measure a tier's excess against every tier below it combined", func(t *testing.T) {
		t.Parallel()
		// given
		suite := counts(2, 1, 0, 5)

		// when
		excess := suite.Excess(entities.TierE2E)

		// then
		assert.Equal(t, 2, excess)
		assert.Equal(t, 3, suite.Below(entities.TierE2E))
		assert.Equal(t, 6, suite.AtOrAbove(entities.TierIntegration))
		assert.Zero(t, suite.Excess(entities.TierIntegration))
	})
}

func TestParseTier(t *testing.T) {
	t.Parallel()

	t.Run("should read every tier by its name and ignore as the ignored tier", func(t *testing.T) {
		t.Parallel()
		// given
		names := []string{"unit", "integration", "functional", "e2e", "ignore"}

		// when
		var tiers []entities.Tier
		for _, name := range names {
			tier, known := entities.ParseTier(name)
			require.True(t, known, name)
			tiers = append(tiers, tier)
		}

		// then
		assert.Equal(t, []entities.Tier{
			entities.TierUnit,
			entities.TierIntegration,
			entities.TierFunctional,
			entities.TierE2E,
			entities.TierIgnored,
		}, tiers)
	})

	t.Run("should not read a name that is no tier", func(t *testing.T) {
		t.Parallel()
		// given
		name := "smoke"

		// when
		_, known := entities.ParseTier(name)

		// then
		assert.False(t, known)
	})
}
