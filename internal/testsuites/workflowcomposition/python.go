package main

import (
	"fmt"
	"math"
	"strconv"
	"strings"
	"unicode"
	"unicode/utf8"
)

// These checks were first written in Python, and both what they find and how they word it depend
// on a few Python behaviours: which characters `\s` and `\w` match, how `str.split()` and
// `str.splitlines()` cut text, and how `repr()` prints a value inside a finding. Each helper below
// is one of those behaviours, so a rewritten check reads a file the way its predecessor did and
// reports a violation in the same words.

// spaceClass is the body of a regular-expression class matching Python's `\s` on a str pattern:
// every character `str.isspace` accepts. Go's own `\s` is ASCII-only, so without it a non-breaking
// space would end a token here that Python read straight through.
const spaceClass = `\t\n\v\f\r\x{1c}-\x{1f} \x{85}\x{a0}\x{1680}\x{2000}-\x{200a}` +
	`\x{2028}\x{2029}\x{202f}\x{205f}\x{3000}`

// space is one Python whitespace character: the `\s` of a pattern.
const space = `[` + spaceClass + `]`

// word is one character of Python's `\w` on a str pattern: a letter, a digit or `_`, in any script.
const word = `[\p{L}\p{N}_]`

// Escape widths of `repr`: `\xNN` up to U+00FF, `\uNNNN` up to U+FFFF, `\UNNNNNNNN` beyond.
const (
	reprByteLimit = 0xff
	reprWideLimit = 0xffff
	asciiDelete   = 0x7f
)

// Python prints a float positionally while the decimal point sits within this window of the
// leading digit, and in exponent notation outside it.
const (
	reprPointMinimum = -4
	reprPointMaximum = 16
)

// isSpace is `str.isspace` for one character: Unicode white space, plus the information separators
// U+001C to U+001F, which Python counts and [unicode.IsSpace] does not.
func isSpace(character rune) bool {
	return unicode.IsSpace(character) || (character >= '\x1c' && character <= '\x1f')
}

// isWord is one character of Python's `\w`.
func isWord(character rune) bool {
	return unicode.IsLetter(character) || unicode.IsNumber(character) || character == '_'
}

// strip is `str.strip()`.
func strip(text string) string {
	return strings.TrimFunc(text, isSpace)
}

// collapse is `' '.join(text.split())`: every run of whitespace becomes one space, and the ends
// lose theirs. It is how a check reads a block-scalar expression as the one line it is.
func collapse(text string) string {
	return strings.Join(strings.FieldsFunc(text, isSpace), " ")
}

// isLineBreak is one of the characters `str.splitlines()` ends a line at. A carriage return
// followed by a line feed is one break, which the caller handles.
func isLineBreak(character rune) bool {
	switch character {
	case '\n', '\r', '\v', '\f', '\x1c', '\x1d', '\x1e', '\x85', '\U00002028', '\U00002029':
		return true
	default:
		return false
	}
}

// splitLines is `str.splitlines()`: the lines of `text` without their breaks, and no empty last
// line for a text that ends with one.
func splitLines(text string) []string {
	var lines []string
	start := 0
	for index := 0; index < len(text); {
		character, size := utf8.DecodeRuneInString(text[index:])
		if !isLineBreak(character) {
			index += size
			continue
		}
		lines = append(lines, text[start:index])
		index += size
		if character == '\r' && strings.HasPrefix(text[index:], "\n") {
			index++
		}
		start = index
	}
	if start < len(text) {
		lines = append(lines, text[start:])
	}
	return lines
}

// boundary is Python's `\b` at byte offset `at` of `text`: a `\w` character on exactly one side.
func boundary(text string, at int) bool {
	before, after := false, false
	if at > 0 {
		character, _ := utf8.DecodeLastRuneInString(text[:at])
		before = isWord(character)
	}
	if at < len(text) {
		character, _ := utf8.DecodeRuneInString(text[at:])
		after = isWord(character)
	}
	return before != after
}

// reprString is Python's `repr()` of a str: single quotes unless the text holds a single quote and
// no double one, with backslashes, the chosen quote, control characters and anything unprintable
// escaped.
func reprString(text string) string {
	quote := '\''
	if strings.ContainsRune(text, '\'') && !strings.ContainsRune(text, '"') {
		quote = '"'
	}
	var out strings.Builder
	out.WriteRune(quote)
	for _, character := range text {
		out.WriteString(reprCharacter(character, quote))
	}
	out.WriteRune(quote)
	return out.String()
}

// reprCharacter is one character of [reprString].
func reprCharacter(character, quote rune) string {
	switch {
	case character == quote || character == '\\':
		return `\` + string(character)
	case character == '\t':
		return `\t`
	case character == '\n':
		return `\n`
	case character == '\r':
		return `\r`
	case character < ' ' || character == asciiDelete:
		return fmt.Sprintf(`\x%02x`, character)
	case character < asciiDelete || unicode.IsPrint(character):
		return string(character)
	case character <= reprByteLimit:
		return fmt.Sprintf(`\x%02x`, character)
	case character <= reprWideLimit:
		return fmt.Sprintf(`\u%04x`, character)
	default:
		return fmt.Sprintf(`\U%08x`, character)
	}
}

// reprFloat is Python's `repr()` of a float: the shortest digits that read back as the same number,
// positional while the decimal point is near them (a whole number keeps a `.0`), and in exponent
// notation otherwise, with at least two exponent digits.
func reprFloat(number float64) string {
	switch {
	case math.IsNaN(number):
		return "nan"
	case math.IsInf(number, 1):
		return "inf"
	case math.IsInf(number, -1):
		return "-inf"
	}
	sign := ""
	if math.Signbit(number) {
		sign, number = "-", -number
	}
	if number == 0 {
		return sign + "0.0"
	}
	mantissa, exponentText, _ := strings.Cut(strconv.FormatFloat(number, 'e', -1, 64), "e")
	digits := strings.Replace(mantissa, ".", "", 1)
	exponent, _ := strconv.Atoi(exponentText)
	// The decimal point sits after this many digits: 1.27 is "127" with the point after 1.
	point := exponent + 1
	switch {
	case point <= reprPointMinimum || point > reprPointMaximum:
		fraction := ""
		if len(digits) > 1 {
			fraction = "." + digits[1:]
		}
		exponentSign := "+"
		if exponent < 0 {
			exponentSign, exponent = "-", -exponent
		}
		return fmt.Sprintf("%s%s%se%s%02d", sign, digits[:1], fraction, exponentSign, exponent)
	case point <= 0:
		return sign + "0." + strings.Repeat("0", -point) + digits
	case point >= len(digits):
		return sign + digits + strings.Repeat("0", point-len(digits)) + ".0"
	default:
		return sign + digits[:point] + "." + digits[point:]
	}
}
