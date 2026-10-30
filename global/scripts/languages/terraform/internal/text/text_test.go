package text_test

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/rios0rios0/pipelines/global/scripts/languages/terraform/internal/text"
)

func TestIsSpace(t *testing.T) {
	t.Parallel()

	t.Run("should count the ASCII separators and Unicode spaces as whitespace when classifying", func(t *testing.T) {
		t.Parallel()
		// given
		spaces := []rune{'\t', '\n', '\v', '\f', '\r', 0x1c, 0x1f, ' ', 0x85, 0xa0, 0x2003, 0x2028, 0x3000}

		// when
		var classified []bool
		for _, r := range spaces {
			classified = append(classified, text.IsSpace(r))
		}

		// then
		assert.NotContains(t, classified, false)
	})

	t.Run("should not count a zero-width or printable character as whitespace when classifying", func(t *testing.T) {
		t.Parallel()
		// given
		others := []rune{'a', '_', 0x1b, 0x200b, 0xfeff, 0x7f}

		// when
		var classified []bool
		for _, r := range others {
			classified = append(classified, text.IsSpace(r))
		}

		// then
		assert.NotContains(t, classified, true)
	})
}

func TestWordBoundaryBefore(t *testing.T) {
	t.Parallel()

	t.Run("should find a boundary after punctuation and at the start when scanning", func(t *testing.T) {
		t.Parallel()
		// given
		subject := "x = var.a + €var.b"

		// when
		atStart := text.WordBoundaryBefore(subject, 0)
		afterSpace := text.WordBoundaryBefore(subject, 4)
		afterEuro := text.WordBoundaryBefore(subject, len("x = var.a + €"))

		// then
		assert.True(t, atStart)
		assert.True(t, afterSpace)
		assert.True(t, afterEuro)
	})

	t.Run("should find no boundary after a letter of any script when scanning", func(t *testing.T) {
		t.Parallel()
		// given
		subject := "évar.a _var.b myvar.c"

		// when
		afterAccent := text.WordBoundaryBefore(subject, len("é"))
		afterUnderscore := text.WordBoundaryBefore(subject, len("évar.a _"))
		afterLetter := text.WordBoundaryBefore(subject, len("évar.a _var.b my"))

		// then
		assert.False(t, afterAccent)
		assert.False(t, afterUnderscore)
		assert.False(t, afterLetter)
	})
}

func TestStrip(t *testing.T) {
	t.Parallel()

	t.Run("should strip Unicode whitespace from both ends when stripping", func(t *testing.T) {
		t.Parallel()
		// given
		padded := "\u00a0\t value \u3000\n"

		// when
		stripped := text.Strip(padded)

		// then
		assert.Equal(t, "value", stripped)
	})

	t.Run("should keep inner whitespace and a zero-width space when stripping", func(t *testing.T) {
		t.Parallel()
		// given
		padded := " a  b\u200b "

		// when
		stripped := text.Strip(padded)

		// then
		assert.Equal(t, "a  b\u200b", stripped)
	})
}

func TestFirstLine(t *testing.T) {
	t.Parallel()

	t.Run("should end the first line at any line break when splitting", func(t *testing.T) {
		t.Parallel()
		// given
		separated := "# marker\u2028second"

		// when
		first := text.FirstLine(separated)

		// then
		assert.Equal(t, "# marker", first)
	})

	t.Run("should keep the whole text when there is no line break", func(t *testing.T) {
		t.Parallel()
		// given
		single := "# marker"

		// when
		first := text.FirstLine(single)

		// then
		assert.Equal(t, "# marker", first)
	})
}

func TestSlice(t *testing.T) {
	t.Parallel()

	t.Run("should count characters rather than bytes when slicing", func(t *testing.T) {
		t.Parallel()
		// given
		typed := "list(é)"

		// when
		inner := text.Slice(typed, len("list("), -1)

		// then
		assert.Equal(t, "é", inner)
	})

	t.Run("should slice to nothing when the range is empty", func(t *testing.T) {
		t.Parallel()
		// given
		malformed := "list("

		// when
		inner := text.Slice(malformed, len("list("), -1)

		// then
		assert.Empty(t, inner)
	})
}

func TestReadStrict(t *testing.T) {
	t.Parallel()

	t.Run("should normalise every line ending when reading", func(t *testing.T) {
		t.Parallel()
		// given
		path := filepath.Join(t.TempDir(), "main.tf")
		require.NoError(t, os.WriteFile(path, []byte("a\r\nb\rc\n"), 0o600))

		// when
		content, err := text.ReadStrict(path)

		// then
		require.NoError(t, err)
		assert.Equal(t, "a\nb\nc\n", content)
	})

	t.Run("should refuse a file that is not UTF-8 when reading", func(t *testing.T) {
		t.Parallel()
		// given
		path := filepath.Join(t.TempDir(), "main.tf")
		require.NoError(t, os.WriteFile(path, []byte("a\xffb"), 0o600))

		// when
		_, err := text.ReadStrict(path)

		// then
		require.ErrorIs(t, err, text.ErrInvalidUTF8)
	})
}

func TestReadReplacing(t *testing.T) {
	t.Parallel()

	t.Run("should replace bytes that are not UTF-8 and keep the lines when reading", func(t *testing.T) {
		t.Parallel()
		// given
		path := filepath.Join(t.TempDir(), "main.tf")
		require.NoError(t, os.WriteFile(path, []byte("a\xff\r\nb"), 0o600))

		// when
		content, err := text.ReadReplacing(path)

		// then
		require.NoError(t, err)
		assert.Equal(t, "a\ufffd\nb", content)
	})
}

func TestEscapeXML(t *testing.T) {
	t.Parallel()

	t.Run("should escape markup and leave quotes alone when escaping", func(t *testing.T) {
		t.Parallel()
		// given
		raw := `a & b < c > "d" 'e'`

		// when
		escaped := text.EscapeXML(raw)

		// then
		assert.Equal(t, `a &amp; b &lt; c &gt; "d" 'e'`, escaped)
	})
}

func TestReprList(t *testing.T) {
	t.Parallel()

	t.Run("should quote names and escape what cannot be shown on one line when listing", func(t *testing.T) {
		t.Parallel()
		// given
		names := []string{"azurerm", "it's", "a\\b", "tab\there", "nl\n", "\x01", "\u200b", "é"}

		// when
		listed := text.ReprList(names)

		// then
		assert.Equal(t, `['azurerm', "it's", 'a\\b', 'tab\there', 'nl\n', '\x01', '\u200b', 'é']`, listed)
	})

	t.Run("should list nothing as an empty pair of brackets", func(t *testing.T) {
		t.Parallel()
		// given
		var names []string

		// when
		listed := text.ReprList(names)

		// then
		assert.Equal(t, "[]", listed)
	})
}
