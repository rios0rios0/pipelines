package reports_test

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/rios0rios0/pipelines/internal/testsuites/terraform-reports/internal/reports"
)

func TestParse(t *testing.T) {
	t.Parallel()

	t.Run("should accept a report with a declaration, a comment and nested elements", func(t *testing.T) {
		t.Parallel()
		// given
		document := `<?xml version="1.0" encoding="UTF-8"?>
<!-- generated -->
<testsuites tests="1"><testsuite name="a &amp; b"><testcase name="x"/></testsuite></testsuites>
`

		// when
		root, err := reports.Parse([]byte(document))

		// then
		require.NoError(t, err)
		assert.Equal(t, "testsuites", root.Name)
		assert.Equal(t, "a & b", root.Children[0].Attributes["name"])
	})

	t.Run("should refuse every document a conforming parser refuses", func(t *testing.T) {
		t.Parallel()
		// given
		malformed := map[string]string{
			"unescaped ampersand":       `<a>x & y</a>`,
			"unescaped quote in value":  `<a b="x "y" z"/>`,
			"mismatched tags":           `<a><b></a></b>`,
			"unclosed root":             `<a><b/>`,
			"two roots":                 `<a/><b/>`,
			"text after the root":       `<a/>trailing`,
			"text before the root":      `leading<a/>`,
			"attribute given twice":     `<a b="1" b="2"/>`,
			"undefined entity":          `<a>&nbsp;</a>`,
			"forbidden character":       "<a>\x01</a>",
			"invalid UTF-8":             "<a>\xff</a>",
			"declaration not at start":  ` <?xml version="1.0"?><a/>`,
			"double dash in a comment":  `<!-- a -- b --><a/>`,
			"comment ending in a dash":  `<!-- a ---><a/>`,
			"empty document":            ``,
			"unquoted attribute":        `<a b=1/>`,
			"DOCTYPE after the root":    `<a/><!DOCTYPE a>`,
			"tag name starting with -":  `<-a/>`,
			"unterminated comment":      `<a/><!-- x`,
			"unterminated attribute":    `<a b="1/>`,
			"element inside attribute":  `<a b="<c/>"/>`,
			"closing tag with no start": `</a>`,
		}

		// when
		accepted := map[string]bool{}
		for name, document := range malformed {
			if _, err := reports.Parse([]byte(document)); err == nil {
				accepted[name] = true
			}
		}

		// then
		assert.Empty(t, accepted)
	})
}

func TestExpectRoot(t *testing.T) {
	t.Parallel()

	t.Run("should pass when the root name, attributes and child count match", func(t *testing.T) {
		t.Parallel()
		// given
		root, err := reports.Parse([]byte(`<coverage version="1"/>`))
		require.NoError(t, err)

		// when
		err = reports.ExpectRoot(root, "coverage", []string{"version=1", "children=0"})

		// then
		require.NoError(t, err)
	})

	t.Run("should fail on a wrong name, attribute or child count", func(t *testing.T) {
		t.Parallel()
		// given
		root, err := reports.Parse([]byte(`<coverage version="2"><file/></coverage>`))
		require.NoError(t, err)

		// when
		wrongName := reports.ExpectRoot(root, "testsuites", nil)
		wrongAttribute := reports.ExpectRoot(root, "coverage", []string{"version=1"})
		wrongChildren := reports.ExpectRoot(root, "coverage", []string{"children=0"})

		// then
		require.ErrorIs(t, wrongName, reports.ErrMismatch)
		require.ErrorIs(t, wrongAttribute, reports.ErrMismatch)
		require.ErrorIs(t, wrongChildren, reports.ErrMismatch)
	})
}

func TestExpectAscendingLines(t *testing.T) {
	t.Parallel()

	t.Run("should pass when the first file's lines strictly increase", func(t *testing.T) {
		t.Parallel()
		// given
		root, err := reports.Parse([]byte(`<c><f><l lineNumber="1"/><l lineNumber="5"/></f></c>`))
		require.NoError(t, err)

		// when
		err = reports.ExpectAscendingLines(root)

		// then
		require.NoError(t, err)
	})

	t.Run("should fail on a line out of order or repeated", func(t *testing.T) {
		t.Parallel()
		// given
		unordered, err := reports.Parse([]byte(`<c><f><l lineNumber="5"/><l lineNumber="1"/></f></c>`))
		require.NoError(t, err)
		repeated, err := reports.Parse([]byte(`<c><f><l lineNumber="5"/><l lineNumber="5"/></f></c>`))
		require.NoError(t, err)

		// when
		unorderedErr := reports.ExpectAscendingLines(unordered)
		repeatedErr := reports.ExpectAscendingLines(repeated)

		// then
		require.ErrorIs(t, unorderedErr, reports.ErrMismatch)
		require.ErrorIs(t, repeatedErr, reports.ErrMismatch)
	})
}
