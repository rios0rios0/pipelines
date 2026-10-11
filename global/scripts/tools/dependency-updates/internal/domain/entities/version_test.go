package entities_test

import (
	"testing"

	"github.com/stretchr/testify/assert"

	"github.com/rios0rios0/pipelines/global/scripts/tools/dependency-updates/internal/domain/entities"
)

func TestIsNewer(t *testing.T) {
	t.Parallel()

	t.Run("should compare only as many components as the pin declares", func(t *testing.T) {
		t.Parallel()
		// given
		pin := "4"

		// when
		sameMajor := entities.IsNewer(pin, "4.123.0")
		nextMajor := entities.IsNewer(pin, "5.0.0")

		// then
		assert.False(t, sameMajor, "a major-only pin is current within its major")
		assert.True(t, nextMajor)
	})

	t.Run("should ignore the spelling around a version", func(t *testing.T) {
		t.Parallel()
		// given
		pin := "codeql-bundle-v2.27.2"

		// when
		newer := entities.IsNewer(pin, "2.27.2")

		// then
		assert.False(t, newer)
	})

	t.Run("should treat any difference as newer when a version cannot be ordered", func(t *testing.T) {
		t.Parallel()
		// given
		pin := "edge"

		// when
		newer := entities.IsNewer(pin, "latest")

		// then
		assert.True(t, newer)
	})
}

func TestTagFamily(t *testing.T) {
	t.Parallel()

	t.Run("should keep the CodeQL bundle and action release lines apart", func(t *testing.T) {
		t.Parallel()
		// given
		bundle, action := "codeql-bundle-v2.27.2", "v4.38.3"

		// when
		bundleFamily, bundleFound := entities.TagFamily(bundle)
		actionFamily, actionFound := entities.TagFamily(action)

		// then
		assert.True(t, bundleFound)
		assert.True(t, actionFound)
		assert.Equal(t, "codeql-bundle", bundleFamily)
		assert.Empty(t, actionFamily, "a leading v is spelling, not a release line")
	})

	t.Run("should find no family in a tag without a digit", func(t *testing.T) {
		t.Parallel()
		// given
		tag := "latest"

		// when
		_, found := entities.TagFamily(tag)

		// then
		assert.False(t, found)
	})
}

func TestRestyle(t *testing.T) {
	t.Parallel()

	cases := map[string][3]string{
		"should drop the v a pin is written without": {"8.30.1", "v8.31.0", "8.31.0"},
		"should keep a tag that is the pin whole": {
			"codeql-bundle-v2.26.4",
			"codeql-bundle-v2.27.2",
			"codeql-bundle-v2.27.2",
		},
		"should keep a major-only pin major-only": {"4", "5.2.0", "5"},
		"should keep the v a pin is written with": {"v1.8.0", "v1.9.0", "v1.9.0"},
	}
	for name, values := range cases {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			// given
			current, latest, want := values[0], values[1], values[2]

			// when
			restyled := entities.Restyle(current, latest)

			// then
			assert.Equal(t, want, restyled)
		})
	}
}

func TestIsPrerelease(t *testing.T) {
	t.Parallel()

	cases := map[string]bool{
		"2.0.0-rc.1":                        true,
		"1.0.0-beta":                        true,
		"1.2.0rc1":                          true,
		"2.30.0a1":                          true,
		"3.0.0.dev2":                        true,
		"1.2.3":                             false,
		"v4.38.3":                           false,
		"codeql-bundle-v2.27.2":             false,
		"0.0.0-20160331181800-b5bfa59ec0ad": false,
		// A hostile name must reach the refusal that names it, not vanish.
		`1.3.0";touch_pwned;"`: false,
	}
	for version, want := range cases {
		t.Run("should classify "+version, func(t *testing.T) {
			t.Parallel()
			// given / when
			prerelease := entities.IsPrerelease(version)

			// then
			assert.Equal(t, want, prerelease)
		})
	}
}

func TestCompareVersions(t *testing.T) {
	t.Parallel()

	t.Run("should treat a missing trailing component as zero", func(t *testing.T) {
		t.Parallel()
		// given
		short, long := "41", "41.0.0"

		// when
		order := entities.CompareVersions(short, long)

		// then
		assert.Zero(t, order)
	})

	t.Run("should order by number, not text", func(t *testing.T) {
		t.Parallel()
		// given
		lower, higher := "1.9.0", "1.10.0"

		// when
		order := entities.CompareVersions(lower, higher)

		// then
		assert.Negative(t, order)
	})
}

func TestInLine(t *testing.T) {
	t.Parallel()

	t.Run("should accept a release inside the major whether or not the major is written with v", func(t *testing.T) {
		t.Parallel()
		// given / when
		plain := entities.InLine("1.26.2", "1")
		prefixed := entities.InLine("v1.26.2", "v1")
		outside := entities.InLine("2.0.0", "1")

		// then
		assert.True(t, plain)
		assert.True(t, prefixed)
		assert.False(t, outside)
	})

	t.Run("should hold a minor line to its own patch releases", func(t *testing.T) {
		t.Parallel()
		// given / when
		patch := entities.InLine("1.27.2", "1.27")
		nextMinor := entities.InLine("1.28.0", "1.27")
		sharedPrefix := entities.InLine("1.270.0", "1.27")
		tooShort := entities.InLine("1", "1.27")

		// then
		assert.True(t, patch)
		assert.False(t, nextMinor)
		assert.False(t, sharedPrefix, "1.270 shares the characters of 1.27, not the line")
		assert.False(t, tooShort)
	})

	t.Run("should name a major and a minor line the way a sentence does", func(t *testing.T) {
		t.Parallel()
		// given / when
		major := entities.LineName("v1")
		minor := entities.LineName("1.27")

		// then
		assert.Equal(t, "major 1", major)
		assert.Equal(t, "the 1.27 line", minor)
	})
}
