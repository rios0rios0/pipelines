package entities_test

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/rios0rios0/pipelines/global/scripts/tools/test-pyramid/internal/domain/entities"
)

func counts(unit, integration, functional, e2e int) entities.Counts {
	return entities.Counts{
		entities.TierUnit:        unit,
		entities.TierIntegration: integration,
		entities.TierFunctional:  functional,
		entities.TierE2E:         e2e,
	}
}

func TestJudge(t *testing.T) {
	t.Parallel()

	t.Run("should keep the pyramid when the pull request adds unit tests", func(t *testing.T) {
		t.Parallel()
		// given
		target, pullRequest := counts(80, 15, 3, 2), counts(90, 15, 3, 2)

		// when
		verdict := entities.Judge("go", target, pullRequest, entities.DefaultMix())

		// then
		assert.False(t, verdict.Worsened())
		assert.Empty(t, verdict.Findings)
		assert.Equal(t, entities.ShapePyramid, verdict.PullRequestShape())
	})

	t.Run("should worsen the pyramid when a tier comes to outnumber every tier below it", func(t *testing.T) {
		t.Parallel()
		// given
		target, pullRequest := counts(3, 1, 0, 0), counts(3, 1, 0, 5)
		mix := entities.Mix{}

		// when
		verdict := entities.Judge("go", target, pullRequest, mix)

		// then
		require.Len(t, verdict.Findings, 1)
		assert.Equal(t, "e2e tests now outnumber every tier below them combined by 1 (not at all on the target branch)",
			verdict.Findings[0])
		assert.Equal(t, entities.ShapeIceCreamCone, verdict.PullRequestShape())
	})

	t.Run("should not hold the pull request to an inversion the target branch already had", func(t *testing.T) {
		t.Parallel()
		// given
		target, pullRequest := counts(1, 0, 0, 10), counts(2, 0, 0, 10)

		// when
		verdict := entities.Judge("javascript", target, pullRequest, entities.Mix{})

		// then
		assert.False(t, verdict.Worsened())
		assert.Equal(t, entities.ShapeIceCreamCone, verdict.TargetShape())
	})

	t.Run("should worsen the pyramid when an inversion the target branch had grows", func(t *testing.T) {
		t.Parallel()
		// given
		target, pullRequest := counts(1, 0, 0, 10), counts(1, 0, 0, 11)

		// when
		verdict := entities.Judge("javascript", target, pullRequest, entities.Mix{})

		// then
		require.Len(t, verdict.Findings, 1)
		assert.Contains(t, verdict.Findings[0], "by 10 (by 9 on the target branch)")
	})

	t.Run("should not count a tier the project does not use against the tiers above it", func(t *testing.T) {
		t.Parallel()
		// given: unit and e2e tests, no integration or functional tier at all
		target, pullRequest := counts(500, 0, 0, 20), counts(500, 0, 0, 21)

		// when
		verdict := entities.Judge("javascript", target, pullRequest, entities.DefaultMix())

		// then
		assert.False(t, verdict.Worsened())
		assert.Equal(t, entities.ShapePyramid, verdict.PullRequestShape())
	})

	t.Run(
		"should worsen the pyramid when the pull request takes the large share past the reference mix",
		func(t *testing.T) {
			t.Parallel()
			// given: 7 of 107 test cases are e2e, above the 6 that 5% leaves them
			target, pullRequest := counts(95, 5, 0, 0), counts(95, 5, 0, 7)

			// when
			verdict := entities.Judge("go", target, pullRequest, entities.DefaultMix())

			// then
			require.Len(t, verdict.Findings, 1)
			assert.Equal(t, "functional and e2e tests are now 6.5% of the suite, above the 5% the reference mix "+
				"leaves them (0.0% on the target branch)", verdict.Findings[0])
			assert.Equal(t, entities.ShapeHourglass, verdict.PullRequestShape())
		},
	)

	t.Run("should worsen the pyramid when integration and above grow past their 20 percent", func(t *testing.T) {
		t.Parallel()
		// given
		target, pullRequest := counts(80, 20, 0, 0), counts(80, 30, 0, 0)

		// when
		verdict := entities.Judge("java", target, pullRequest, entities.DefaultMix())

		// then
		require.Len(t, verdict.Findings, 1)
		assert.Contains(t, verdict.Findings[0], "integration, functional and e2e tests are now 27.3% of the suite")
		assert.Equal(t, entities.ShapeTopHeavy, verdict.PullRequestShape())
	})

	t.Run(
		"should not hold the pull request to a mix the target branch was past when its share does not grow",
		func(t *testing.T) {
			t.Parallel()
			// given: 20 of 100 and 21 of 105 are the same share
			target, pullRequest := counts(80, 0, 0, 20), counts(84, 0, 0, 21)

			// when
			verdict := entities.Judge("php", target, pullRequest, entities.DefaultMix())

			// then
			assert.False(t, verdict.Worsened())
		},
	)

	t.Run("should round each allowance up so a small suite with one integration test passes", func(t *testing.T) {
		t.Parallel()
		// given: the first tests of a new repository
		target, pullRequest := counts(0, 0, 0, 0), counts(3, 1, 0, 0)

		// when
		verdict := entities.Judge("python", target, pullRequest, entities.DefaultMix())

		// then
		assert.False(t, verdict.Worsened())
		assert.Equal(t, entities.ShapeNoTests, verdict.TargetShape())
	})

	t.Run("should judge the shape alone when the mix is off", func(t *testing.T) {
		t.Parallel()
		// given
		target, pullRequest := counts(50, 10, 0, 0), counts(50, 10, 0, 20)

		// when
		judged := entities.Judge("ruby", target, pullRequest, entities.DefaultMix())
		unjudged := entities.Judge("ruby", target, pullRequest, entities.Mix{})

		// then
		assert.True(t, judged.Worsened())
		assert.False(t, unjudged.Worsened())
		assert.Equal(t, entities.ShapePyramid, unjudged.PullRequestShape())
	})
}

func TestShare(t *testing.T) {
	t.Parallel()

	t.Run("should give a share to one decimal", func(t *testing.T) {
		t.Parallel()
		// given
		part, total := 1, 3

		// when
		share := entities.Share(part, total)

		// then
		assert.Equal(t, "33.3%", share)
	})

	t.Run("should give no share of an empty suite", func(t *testing.T) {
		t.Parallel()
		// given
		part, total := 0, 0

		// when
		share := entities.Share(part, total)

		// then
		assert.Equal(t, "-", share)
	})
}
