package repositories_test

import (
	"crypto/sha256"
	"encoding/hex"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/rios0rios0/pipelines/global/scripts/languages/golang/cyclonedx/licenses/internal/infrastructure/repositories"
)

// upstreamSHA256 is the digest of CycloneDX's schema/spdx.schema.json at commit
// f33fae5e868cf1b79cfb9e8a9a8537087be5b1b7, the file cyclonedx-core-java 11.0.1 and 12.1.0 bundle.
const upstreamSHA256 = "54a6288292bc6c90b0d3952f5f939f17436fa76704ffe68a46e5b78539c7cc1b"

func TestEmbeddedLicenseListRepository(t *testing.T) {
	t.Parallel()

	t.Run("should embed the upstream file byte for byte when built", func(t *testing.T) {
		t.Parallel()
		// given
		schema := repositories.EmbeddedSPDXSchema()

		// when
		digest := sha256.Sum256(schema)

		// then
		assert.Equal(t, upstreamSHA256, hex.EncodeToString(digest[:]))
	})

	t.Run("should load the SPDX license list 3.27.0 when asked for the list", func(t *testing.T) {
		t.Parallel()
		// given
		repository := repositories.NewEmbeddedLicenseListRepository()

		// when
		list, err := repository.Load()

		// then
		require.NoError(t, err)
		assert.Equal(t, "v1.0-3.27.0", list.Version())
		assert.Equal(t, 778, list.Len())
		for _, id := range []string{"MIT", "Apache-2.0", "BSD-3-Clause", "GPL-2.0+", "GPL-2.0-or-later", "FTL"} {
			assert.True(t, list.Holds(id), "the list holds %q", id)
		}
		assert.False(t, list.Holds("deprecated_GPL-2.0+"))
	})
}

func TestParseLicenseList(t *testing.T) {
	t.Parallel()

	t.Run("should read the enumeration and its label when the schema is well formed", func(t *testing.T) {
		t.Parallel()
		// given
		schema := []byte(`{"$comment": "v1.0-3.27.0", "type": "string", "enum": ["0BSD", "MIT"]}`)

		// when
		list, err := repositories.ParseLicenseList(schema)

		// then
		require.NoError(t, err)
		assert.Equal(t, "v1.0-3.27.0", list.Version())
		assert.Equal(t, 2, list.Len())
	})

	t.Run("should fail when the schema is not JSON", func(t *testing.T) {
		t.Parallel()
		// given
		schema := []byte(`{"enum": [`)

		// when
		_, err := repositories.ParseLicenseList(schema)

		// then
		assert.ErrorContains(t, err, "could not read the SPDX schema")
	})

	t.Run("should fail when the schema enumerates no id", func(t *testing.T) {
		t.Parallel()
		// given
		schema := []byte(`{"$comment": "v1.0-3.27.0", "type": "string"}`)

		// when
		_, err := repositories.ParseLicenseList(schema)

		// then
		assert.ErrorIs(t, err, repositories.ErrEmptyLicenseList)
	})
}
