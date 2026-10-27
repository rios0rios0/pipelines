package entities_test

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/rios0rios0/pipelines/global/scripts/tools/dependency-updates/internal/domain/entities"
)

func TestFindDrift(t *testing.T) {
	t.Parallel()

	t.Run("should read each package of one pip install against its own pin", func(t *testing.T) {
		t.Parallel()
		// given
		files := []entities.SourceText{{
			Path: "action.yaml",
			Text: `python -m pip install --only-binary :all: "pdm==2.29.2" "unearth==0.18.2"` + "\n",
		}}
		expected := map[string]string{"PDM_SPEC": "2.29.2", "UNEARTH_SPEC": "0.18.3"}

		// when
		drifts := entities.FindDrift(files, expected)

		// then
		require.Len(t, drifts, 1)
		assert.Equal(t, "UNEARTH_SPEC", drifts[0].Name)
		assert.Equal(t, "0.18.2", drifts[0].Inline)
		assert.Equal(t, "0.18.3", drifts[0].Manifest)
	})

	t.Run("should report nothing when every copy agrees with its pin", func(t *testing.T) {
		t.Parallel()
		// given
		files := []entities.SourceText{{
			Path: "Dockerfile",
			Text: `RUN pip install --only-binary :all: "pdm==2.29.2" "unearth==0.18.3"` + "\n",
		}}
		expected := map[string]string{"PDM_SPEC": "2.29.2", "UNEARTH_SPEC": "0.18.3"}

		// when
		drifts := entities.FindDrift(files, expected)

		// then
		assert.Empty(t, drifts)
	})
}
