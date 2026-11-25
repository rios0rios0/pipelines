package entities_test

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/rios0rios0/pipelines/global/scripts/tools/test-pyramid/internal/domain/entities"
)

func TestParsePolicy(t *testing.T) {
	t.Parallel()

	t.Run("should read every setting and the path rules in their order", func(t *testing.T) {
		t.Parallel()
		// given
		text := "# the platform team's policy\n" +
			"blocking true\n" +
			"mix 70/20/10\n" +
			"languages go javascript\n" +
			"\n" +
			"e2e ^qa/\n" +
			"ignore ^benchmarks/\n" +
			"unit ^qa/fast/\n"

		// when
		policy, err := entities.ParsePolicy(text)

		// then
		require.NoError(t, err)
		assert.True(t, policy.Blocking)
		assert.Equal(t, "70/20/10", policy.Mix.String())
		assert.Equal(t, []string{"go", "javascript"}, policy.Languages)
		require.Len(t, policy.Rules, 3)
		assert.Equal(t, entities.TierE2E, policy.Rules[0].Tier)
		assert.Equal(t, entities.TierIgnored, policy.Rules[1].Tier)
		assert.Equal(t, "^qa/fast/", policy.Rules[2].Pattern.String())
	})

	t.Run("should keep the defaults a file does not set", func(t *testing.T) {
		t.Parallel()
		// given
		text := "# nothing but a comment\n"

		// when
		policy, err := entities.ParsePolicy(text)

		// then
		require.NoError(t, err)
		assert.Equal(t, entities.DefaultPolicy().String(), policy.String())
		assert.False(t, policy.Blocking)
		assert.Equal(t, "80/15/5", policy.Mix.String())
	})

	t.Run("should turn the mix off", func(t *testing.T) {
		t.Parallel()
		// given
		text := "mix off\n"

		// when
		policy, err := entities.ParsePolicy(text)

		// then
		require.NoError(t, err)
		assert.False(t, policy.Mix.Judged)
	})

	t.Run("should report every problem with its line instead of ignoring a setting", func(t *testing.T) {
		t.Parallel()
		// given
		text := "blocking yes\n" +
			"mix 80/15/15\n" +
			"mix 80/15/5\n" +
			"languages Go\n" +
			"e2e ^qa/(\n" +
			"smoke ^smoke/\n" +
			"integration\n" +
			"blocking false\n"

		// when
		_, err := entities.ParsePolicy(text)

		// then
		var problems *entities.PolicyError
		require.ErrorAs(t, err, &problems)
		assert.Equal(t, []string{
			`line 1: blocking is true or false, not "yes"`,
			"line 2: the mix percentages 80/15/15 do not add up to 100",
			`line 3: "mix" is set twice`,
			`line 4: languages lists lower-case language names, not "Go"`,
			"line 5: \"^qa/(\" is not a valid regular expression: error parsing regexp: missing closing ): `^qa/(`",
			`line 6: unknown setting "smoke" (known: blocking, mix, languages, unit, integration, functional, e2e, ignore)`,
			`line 7: "integration" needs a regular expression for the paths it names`,
			`line 8: "blocking" is set twice`,
		}, problems.Problems)
	})

	t.Run("should refuse a mix that is not three whole percentages", func(t *testing.T) {
		t.Parallel()
		// given
		text := "mix 80/20\n"

		// when
		_, err := entities.ParsePolicy(text)

		// then
		require.EqualError(t, err,
			`line 1: mix is <unit>/<integration>/<functional and e2e> whole percentages, or off, not "80/20"`)
	})

	t.Run("should say two files mean the same when only their layout differs", func(t *testing.T) {
		t.Parallel()
		// given
		spaced := "  blocking   true\r\nmix 80/15/5\r\n"
		plain := "blocking true\n"

		// when
		first, firstErr := entities.ParsePolicy(spaced)
		second, secondErr := entities.ParsePolicy(plain)

		// then
		require.NoError(t, firstErr)
		require.NoError(t, secondErr)
		assert.Equal(t, second.String(), first.String())
	})
}
