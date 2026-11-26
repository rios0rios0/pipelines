package commands_test

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/rios0rios0/pipelines/global/scripts/languages/golang/cyclonedx/licenses/internal/domain/commands"
	"github.com/rios0rios0/pipelines/global/scripts/languages/golang/cyclonedx/licenses/internal/domain/entities"
	"github.com/rios0rios0/pipelines/global/scripts/languages/golang/cyclonedx/licenses/internal/test/doubles"
)

const deprecatedBOM = `{"components":[{"evidence":{"licenses":[{"license":{"id":"deprecated_GPL-2.0+"}}]}}]}`

func licenses() *doubles.StubLicenseListRepository {
	return doubles.NewStubLicenseListRepository("v1.0-3.27.0", "GPL-2.0+", "MIT")
}

func TestNormalizeLicensesCommand(t *testing.T) {
	t.Parallel()

	t.Run("should write the BOM back once when it rewrote an id", func(t *testing.T) {
		t.Parallel()
		// given
		boms := doubles.NewInMemoryBOMRepository(deprecatedBOM)

		// when
		result, err := commands.NewNormalizeLicensesCommand(boms, licenses()).Execute()

		// then
		require.NoError(t, err)
		assert.Equal(t, "v1.0-3.27.0", result.List)
		assert.Equal(t, 1, result.Checked)
		require.Len(t, result.Fixes, 1)
		assert.Equal(t, entities.VerdictRestored, result.Fixes[0].Resolution.Verdict)
		require.Len(t, boms.Writes, 1)
		assert.JSONEq(t, `{"components":[{"evidence":{"licenses":[{"license":{"id":"GPL-2.0+"}}]}}]}`,
			string(boms.Writes[0]))
	})

	t.Run("should not write the BOM when the list holds every id", func(t *testing.T) {
		t.Parallel()
		// given
		boms := doubles.NewInMemoryBOMRepository(`{"components":[{"licenses":[{"license":{"id":"MIT"}}]}]}`)

		// when
		result, err := commands.NewNormalizeLicensesCommand(boms, licenses()).Execute()

		// then
		require.NoError(t, err)
		assert.Equal(t, 1, result.Checked)
		assert.Empty(t, result.Fixes)
		assert.Empty(t, boms.Writes)
	})

	t.Run("should fail and write nothing when the license list cannot be loaded", func(t *testing.T) {
		t.Parallel()
		// given
		boms := doubles.NewInMemoryBOMRepository(deprecatedBOM)
		list := licenses()
		list.Fail = true

		// when
		_, err := commands.NewNormalizeLicensesCommand(boms, list).Execute()

		// then
		require.ErrorIs(t, err, doubles.ErrUnavailable)
		require.ErrorContains(t, err, "could not load the SPDX license list")
		assert.Empty(t, boms.Writes)
	})

	t.Run("should fail when the BOM cannot be read", func(t *testing.T) {
		t.Parallel()
		// given
		boms := doubles.NewInMemoryBOMRepository(deprecatedBOM)
		boms.FailOnRead = true

		// when
		_, err := commands.NewNormalizeLicensesCommand(boms, licenses()).Execute()

		// then
		require.ErrorIs(t, err, doubles.ErrUnavailable)
		require.ErrorContains(t, err, "could not read the BOM")
	})

	t.Run("should fail and write nothing when the BOM is not JSON", func(t *testing.T) {
		t.Parallel()
		// given
		boms := doubles.NewInMemoryBOMRepository(`{"components": [`)

		// when
		_, err := commands.NewNormalizeLicensesCommand(boms, licenses()).Execute()

		// then
		require.ErrorIs(t, err, entities.ErrNotJSON)
		assert.Empty(t, boms.Writes)
	})

	t.Run("should fail when the rewritten BOM cannot be written", func(t *testing.T) {
		t.Parallel()
		// given
		boms := doubles.NewInMemoryBOMRepository(deprecatedBOM)
		boms.FailOnWrite = true

		// when
		_, err := commands.NewNormalizeLicensesCommand(boms, licenses()).Execute()

		// then
		require.ErrorIs(t, err, doubles.ErrUnavailable)
		require.ErrorContains(t, err, "could not write the BOM")
	})
}
