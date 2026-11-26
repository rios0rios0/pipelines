package entities_test

import (
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/rios0rios0/pipelines/global/scripts/languages/golang/cyclonedx/licenses/internal/domain/entities"
)

// freetypeBOM is the shape cyclonedx-gomod v1.12.0 (`app -packages -files -licenses`) wrote for a
// consumer's service on 2026-11-26, cut down to two modules: github.com/golang/freetype's license
// came out under the name of its SPDX license-list file, after the module's packages, and
// Dependency-Track refused the BOM over that one id.
const freetypeBOM = `{
  "$schema": "http://cyclonedx.org/schema/bom-1.6.schema.json",
  "bomFormat": "CycloneDX",
  "specVersion": "1.6",
  "components": [
    {
      "bom-ref": "pkg:golang/github.com/go-pdf/fpdf@v0.9.0?type=module",
      "type": "library",
      "name": "github.com/go-pdf/fpdf",
      "evidence": {
        "licenses": [
          {
            "license": {
              "id": "MIT"
            }
          }
        ]
      }
    },
    {
      "bom-ref": "pkg:golang/github.com/golang/freetype@v0.0.0-20170609003504-e2365dfdc4a0?type=module",
      "type": "library",
      "name": "github.com/golang/freetype",
      "components": [
        {
          "type": "library",
          "name": "github.com/golang/freetype/truetype"
        }
      ],
      "evidence": {
        "licenses": [
          {
            "license": {
              "id": "deprecated_GPL-2.0+"
            }
          }
        ]
      }
    }
  ]
}
`

func spdxList() entities.LicenseList {
	return entities.NewLicenseList("v1.0-3.27.0", []string{"Apache-2.0", "BSD-3-Clause", "GPL-2.0+", "MIT"})
}

func TestNormalizeLicenses(t *testing.T) {
	t.Parallel()

	t.Run("should restore the SPDX id and change no other byte when a deprecated id comes under its file name",
		func(t *testing.T) {
			t.Parallel()
			// given
			document := []byte(freetypeBOM)

			// when
			normalized, err := entities.NormalizeLicenses(document, spdxList())

			// then
			require.NoError(t, err)
			assertDocument(t, strings.Replace(freetypeBOM, `"deprecated_GPL-2.0+"`, `"GPL-2.0+"`, 1),
				normalized.Document)
			assert.Equal(t, 2, normalized.Checked)
			assert.Equal(t, []entities.Fix{{
				Path:       "$.components[1].evidence.licenses[0].license",
				Written:    "deprecated_GPL-2.0+",
				Resolution: entities.Resolution{Verdict: entities.VerdictRestored, ID: "GPL-2.0+"},
			}}, normalized.Fixes)
		})

	t.Run("should write the id as the license name when the list does not hold it", func(t *testing.T) {
		t.Parallel()
		// given
		document := []byte(strings.Replace(freetypeBOM, `"MIT"`, `"LicenseRef-acme"`, 1))

		// when
		normalized, err := entities.NormalizeLicenses(document, spdxList())

		// then
		require.NoError(t, err)
		expected := strings.Replace(
			strings.Replace(freetypeBOM, `"id": "MIT"`, `"name": "LicenseRef-acme"`, 1),
			`"deprecated_GPL-2.0+"`, `"GPL-2.0+"`, 1)
		assertDocument(t, expected, normalized.Document)
		require.Len(t, normalized.Fixes, 2)
		assert.Equal(t, entities.Fix{
			Path:       "$.components[0].evidence.licenses[0].license",
			Written:    "LicenseRef-acme",
			Resolution: entities.Resolution{Verdict: entities.VerdictNamed, ID: "LicenseRef-acme"},
		}, normalized.Fixes[0])
	})

	t.Run("should return the document as it was when the list holds every id", func(t *testing.T) {
		t.Parallel()
		// given
		document := []byte(strings.Replace(freetypeBOM, "deprecated_GPL-2.0+", "GPL-2.0+", 1))

		// when
		normalized, err := entities.NormalizeLicenses(document, spdxList())

		// then
		require.NoError(t, err)
		assert.Equal(t, document, normalized.Document)
		assert.Equal(t, 2, normalized.Checked)
		assert.Empty(t, normalized.Fixes)
	})

	t.Run("should reach every license choice when the metadata, a service and a nested component hold one",
		func(t *testing.T) {
			t.Parallel()
			// given
			document := []byte(`{"metadata":{"licenses":[{"license":{"id":"deprecated_GPL-2.0+"}}],` +
				`"component":{"licenses":[{"license":{"id":"Foo"}}]}},` +
				`"services":[{"name":"api","licenses":[{"license":{"id":"MIT"}},{"license":{"id":"Bar"}}]}],` +
				`"components":[{"components":[{"evidence":{"licenses":[{"license":{"id":"Baz"}}]}}]}]}`)

			// when
			normalized, err := entities.NormalizeLicenses(document, spdxList())

			// then
			require.NoError(t, err)
			assert.JSONEq(t, `{"metadata":{"licenses":[{"license":{"id":"GPL-2.0+"}}],`+
				`"component":{"licenses":[{"license":{"name":"Foo"}}]}},`+
				`"services":[{"name":"api","licenses":[{"license":{"id":"MIT"}},{"license":{"name":"Bar"}}]}],`+
				`"components":[{"components":[{"evidence":{"licenses":[{"license":{"name":"Baz"}}]}}]}]}`,
				string(normalized.Document))
			assert.Equal(t, 5, normalized.Checked)
			assert.Equal(t, []string{
				"$.metadata.licenses[0].license",
				"$.metadata.component.licenses[0].license",
				"$.services[0].licenses[1].license",
				"$.components[0].components[0].evidence.licenses[0].license",
			}, paths(normalized.Fixes))
		})

	t.Run("should leave an object as written when it is no license choice", func(t *testing.T) {
		t.Parallel()
		// given
		document := []byte(`{"license":{"id":"Foo"},"licenses":{"license":{"id":"Bar"}},` +
			`"properties":[{"license":{"id":"Baz"}}],"licenses ":[{"license":{"id":"Qux"}}]}`)

		// when
		normalized, err := entities.NormalizeLicenses(document, spdxList())

		// then
		require.NoError(t, err)
		assert.Equal(t, document, normalized.Document)
		assert.Zero(t, normalized.Checked)
	})

	t.Run("should leave an expression and an object holding both id and name as written", func(t *testing.T) {
		t.Parallel()
		// given
		document := []byte(`{"components":[{"licenses":[{"expression":"deprecated_GPL-2.0+ OR MIT"}]},` +
			`{"licenses":[{"license":{"id":"Foo","name":"Foo License"}}]},` +
			`{"licenses":[{"license":{"name":"Bar License"}}]}]}`)

		// when
		normalized, err := entities.NormalizeLicenses(document, spdxList())

		// then
		require.NoError(t, err)
		assert.Equal(t, document, normalized.Document)
		assert.Equal(t, 1, normalized.Checked)
		assert.Empty(t, normalized.Fixes)
	})

	t.Run("should rewrite the id wherever it sits when the key is escaped or follows other members",
		func(t *testing.T) {
			t.Parallel()
			// given
			document := []byte(`{"licenses":[{"license":{"url":"https://example.test/l","id":"Foo"}},` +
				`{"license" : { "id" :  "deprecated_GPL-2.0+" , "text" : {"content":"x"} }}]}`)

			// when
			normalized, err := entities.NormalizeLicenses(document, spdxList())

			// then
			require.NoError(t, err)
			assertDocument(t, `{"licenses":[{"license":{"url":"https://example.test/l","name":"Foo"}},`+
				`{"license" : { "id" :  "GPL-2.0+" , "text" : {"content":"x"} }}]}`, normalized.Document)
		})

	t.Run("should rewrite both ids when one license object holds another", func(t *testing.T) {
		t.Parallel()
		// given
		document := []byte(`{"licenses":[{"license":{"id":"Foo","licenses":[{"license":{"id":"Bar"}}]}}]}`)

		// when
		normalized, err := entities.NormalizeLicenses(document, spdxList())

		// then
		require.NoError(t, err)
		assertDocument(t, `{"licenses":[{"license":{"name":"Foo","licenses":[{"license":{"name":"Bar"}}]}}]}`,
			normalized.Document)
		assert.Equal(t, []string{
			"$.licenses[0].license.licenses[0].license",
			"$.licenses[0].license",
		}, paths(normalized.Fixes))
	})

	t.Run("should fail when the document is not one JSON document", func(t *testing.T) {
		t.Parallel()
		for _, document := range []string{"", `{"licenses": [`, `{} {}`, `{"a": 1,}`} {
			// given
			input := []byte(document)

			// when
			_, err := entities.NormalizeLicenses(input, spdxList())

			// then
			require.ErrorIs(t, err, entities.ErrNotJSON, "document %q", document)
		}
	})
}

// assertDocument fails unless `got` is `want` byte for byte. The rewrite promises to keep the
// generator's formatting, so a document that only means the same is not enough; the lines are
// compared so that a failure shows which one differs.
func assertDocument(t *testing.T, want string, got []byte) {
	t.Helper()
	assert.Equal(t, strings.SplitAfter(want, "\n"), strings.SplitAfter(string(got), "\n"))
}

func paths(fixes []entities.Fix) []string {
	found := make([]string, 0, len(fixes))
	for _, fix := range fixes {
		found = append(found, fix.Path)
	}
	return found
}
