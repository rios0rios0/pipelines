package entities_test

import (
	"testing"

	"github.com/stretchr/testify/assert"

	"github.com/rios0rios0/pipelines/global/scripts/languages/golang/cyclonedx/licenses/internal/domain/entities"
)

func TestLicenseList(t *testing.T) {
	t.Parallel()

	list := entities.NewLicenseList("v1.0-3.27.0", []string{"MIT", "GPL-2.0+", "GPL-2.0-or-later"})

	t.Run("should keep an id when the list holds it", func(t *testing.T) {
		t.Parallel()
		// given
		id := "GPL-2.0+"

		// when
		resolution := list.Resolve(id)

		// then
		assert.Equal(t, entities.Resolution{Verdict: entities.VerdictListed, ID: "GPL-2.0+"}, resolution)
	})

	t.Run("should restore the SPDX id when a deprecated license comes under its file name", func(t *testing.T) {
		t.Parallel()
		// given
		id := entities.DeprecatedPrefix + "GPL-2.0+"

		// when
		resolution := list.Resolve(id)

		// then
		assert.Equal(t, entities.Resolution{Verdict: entities.VerdictRestored, ID: "GPL-2.0+"}, resolution)
	})

	t.Run("should name the license when the list does not hold the id", func(t *testing.T) {
		t.Parallel()
		// given
		id := "LicenseRef-acme"

		// when
		resolution := list.Resolve(id)

		// then
		assert.Equal(t, entities.Resolution{Verdict: entities.VerdictNamed, ID: "LicenseRef-acme"}, resolution)
	})

	t.Run("should name the license when the id without its prefix is not listed either", func(t *testing.T) {
		t.Parallel()
		// given
		id := entities.DeprecatedPrefix + "Nunit"

		// when
		resolution := list.Resolve(id)

		// then
		assert.Equal(t, entities.Resolution{Verdict: entities.VerdictNamed, ID: "deprecated_Nunit"}, resolution)
	})

	t.Run("should compare ids case-sensitively when the schema enumeration does", func(t *testing.T) {
		t.Parallel()
		// given
		id := "mit"

		// when
		resolution := list.Resolve(id)

		// then
		assert.Equal(t, entities.VerdictNamed, resolution.Verdict)
		assert.True(t, list.Holds("MIT"))
		assert.False(t, list.Holds("mit"))
	})

	t.Run("should report its version and size when built", func(t *testing.T) {
		t.Parallel()
		// given
		ids := []string{"MIT", "MIT", "0BSD"}

		// when
		built := entities.NewLicenseList("v1.0-3.27.0", ids)

		// then
		assert.Equal(t, "v1.0-3.27.0", built.Version())
		assert.Equal(t, 2, built.Len())
	})
}
