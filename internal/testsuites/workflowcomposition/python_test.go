package main

import (
	"math"
	"regexp"
	"testing"
	"unicode"

	"github.com/stretchr/testify/assert"
)

func TestSplitLines(t *testing.T) {
	t.Parallel()

	cases := map[string]struct {
		text  string
		lines []string
	}{
		"should split at every break Python splits at when the text mixes them": {
			"a\nb\rc\r\nd\ve\ff\x1cg\x1dh\x1ei\u0085j\U00002028k\U00002029l",
			[]string{"a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l"},
		},
		"should not add an empty last line when the text ends with a break": {"a\n", []string{"a"}},
		"should keep the empty line between two breaks when they are adjacent": {
			"a\r\n\r\nb", []string{"a", "", "b"},
		},
		"should return no lines when the text is empty":                {"", nil},
		"should return the text itself when it holds no break":         {"a b", []string{"a b"}},
		"should return one empty line when the text is a single break": {"\n", []string{""}},
	}
	for name, values := range cases {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			// given
			text := values.text

			// when
			lines := splitLines(text)

			// then
			assert.Equal(t, values.lines, lines)
		})
	}
}

func TestSpaceClass(t *testing.T) {
	t.Parallel()

	t.Run("should accept the same characters as isSpace when every one up to U+3000 is tried", func(t *testing.T) {
		t.Parallel()
		// given
		class := regexp.MustCompile(`^` + space + `$`)

		// when
		var disagreements []rune
		for character := range rune(0x3001) {
			if class.MatchString(string(character)) != isSpace(character) {
				disagreements = append(disagreements, character)
			}
		}

		// then
		assert.Empty(t, disagreements)
	})

	t.Run("should count the information separators as space when Go's unicode does not", func(t *testing.T) {
		t.Parallel()
		// given
		separator := '\x1f'

		// when
		python, golang := isSpace(separator), unicode.IsSpace(separator)

		// then
		assert.True(t, python)
		assert.False(t, golang)
	})

	t.Run("should collapse every run of Python whitespace when the text is joined", func(t *testing.T) {
		t.Parallel()
		// given
		text := "\U000000a0 a\t\n b\x1c\U00003000c  "

		// when
		collapsed := collapse(text)

		// then
		assert.Equal(t, "a b c", collapsed)
	})
}

func TestBoundary(t *testing.T) {
	t.Parallel()

	cases := map[string]struct {
		text string
		at   int
		want bool
	}{
		"should find a boundary at the start when a word starts the text":       {"word", 0, true},
		"should find a boundary at the end when a word ends the text":           {"word", 4, true},
		"should find no boundary inside a word":                                 {"word", 2, false},
		"should find no boundary between two spaces":                            {"a  b", 2, false},
		"should treat a letter of another script as a word character":           {"éa", 2, false},
		"should treat a digit as a word character when it follows a letter":     {"a1", 1, false},
		"should treat an underscore as a word character when it precedes a dot": {"_.", 1, true},
	}
	for name, values := range cases {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			// given
			text, at := values.text, values.at

			// when
			got := boundary(text, at)

			// then
			assert.Equal(t, values.want, got)
		})
	}
}

func TestReprString(t *testing.T) {
	t.Parallel()

	cases := map[string]struct{ text, want string }{
		"should use single quotes when the text holds no quote":              {"abc", `'abc'`},
		"should use double quotes when the text holds only single quotes":    {"it's", `"it's"`},
		"should escape the single quote when the text holds both quotes":     {`both ' and "`, `'both \' and "'`},
		"should escape tabs, newlines and backslashes when they are present": {"a\tb\nc\\d\re", `'a\tb\nc\\d\re'`},
		"should escape other control characters as bytes":                    {"\x01\x7f", `'\x01\x7f'`},
		"should keep a printable letter of another script":                   {"é", `'é'`},
		"should escape a non-breaking space when it is not printable":        {"\U000000a0", `'\xa0'`},
		"should escape a zero-width space with four digits":                  {"\U0000200b", "'\\" + "u200b'"},
		"should escape a tag character with eight digits":                    {"\U000e0001", `'\U000e0001'`},
	}
	for name, values := range cases {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			// given
			text := values.text

			// when
			got := reprString(text)

			// then
			assert.Equal(t, values.want, got)
		})
	}
}

func TestReprFloat(t *testing.T) {
	t.Parallel()

	cases := map[string]struct {
		number float64
		want   string
	}{
		"should print the shortest digits when the number has a fraction":       {1.27, "1.27"},
		"should keep a .0 when the number is whole":                             {100, "100.0"},
		"should stay positional when the point is sixteen digits in":            {1e15, "1000000000000000.0"},
		"should switch to an exponent when the point is seventeen digits in":    {1e16, "1e+16"},
		"should stay positional when the number is one ten-thousandth":          {0.0001, "0.0001"},
		"should switch to an exponent when the number is smaller":               {0.00001, "1e-05"},
		"should keep a fraction in the mantissa when the exponent form has one": {1.5e-7, "1.5e-07"},
		"should keep three exponent digits when the exponent needs them":        {1e300, "1e+300"},
		"should print every digit when the shortest round trip needs seventeen": {
			0.30000000000000004,
			"0.30000000000000004",
		},
		"should keep the sign of a negative zero":                  {math.Copysign(0, -1), "-0.0"},
		"should print nan when the number is not one":              {math.NaN(), "nan"},
		"should print inf when the number is infinite":             {math.Inf(1), "inf"},
		"should print -inf when the number is negatively infinite": {math.Inf(-1), "-inf"},
	}
	for name, values := range cases {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			// given
			number := values.number

			// when
			got := reprFloat(number)

			// then
			assert.Equal(t, values.want, got)
		})
	}
}
