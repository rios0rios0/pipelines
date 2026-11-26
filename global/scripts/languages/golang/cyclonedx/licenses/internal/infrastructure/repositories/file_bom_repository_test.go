package repositories_test

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/rios0rios0/pipelines/global/scripts/languages/golang/cyclonedx/licenses/internal/infrastructure/repositories"
)

func TestFileBOMRepository(t *testing.T) {
	t.Parallel()

	t.Run("should read the file as written when it exists", func(t *testing.T) {
		t.Parallel()
		// given
		path := filepath.Join(t.TempDir(), "bom.json")
		require.NoError(t, os.WriteFile(path, []byte(`{"bomFormat":"CycloneDX"}`), 0o600))

		// when
		document, err := repositories.NewFileBOMRepository(path).Read()

		// then
		require.NoError(t, err)
		assert.JSONEq(t, `{"bomFormat":"CycloneDX"}`, string(document))
	})

	t.Run("should replace the bytes and keep the permissions when writing", func(t *testing.T) {
		t.Parallel()
		// given
		path := filepath.Join(t.TempDir(), "bom.json")
		require.NoError(t, os.WriteFile(path, []byte(`{"version":1,"padding":"longer than what replaces it"}`), 0o600))
		require.NoError(t, os.Chmod(path, 0o640))

		// when
		err := repositories.NewFileBOMRepository(path).Write([]byte(`{"version":2}`))

		// then
		require.NoError(t, err)
		written, readErr := os.ReadFile(path)
		require.NoError(t, readErr)
		assert.JSONEq(t, `{"version":2}`, string(written))
		info, statErr := os.Stat(path)
		require.NoError(t, statErr)
		assert.Equal(t, os.FileMode(0o640), info.Mode().Perm())
	})

	t.Run("should fail and create nothing when the file does not exist", func(t *testing.T) {
		t.Parallel()
		// given
		path := filepath.Join(t.TempDir(), "missing.json")
		repository := repositories.NewFileBOMRepository(path)

		// when
		_, readErr := repository.Read()
		writeErr := repository.Write([]byte(`{}`))

		// then
		require.ErrorIs(t, readErr, os.ErrNotExist)
		require.ErrorIs(t, writeErr, os.ErrNotExist)
		assert.NoFileExists(t, path)
	})
}
