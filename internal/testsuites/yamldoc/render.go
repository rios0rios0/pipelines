package yamldoc

import (
	"fmt"
	"math"
	"strconv"
	"strings"
	"unicode"
)

// The decimal-point positions between which a float is written out in full
// rather than with an exponent: 0.0001 and 1e16 are the first values outside.
const (
	fixedNotationLow  = -4
	fixedNotationHigh = 16
)

// Str renders the value as text: a string as itself, `None` for an absent or
// null value, `True`/`False`, a number in its shortest exact form, and a
// mapping or sequence as Repr renders it. The suites' messages were first
// written in Python, and this is Python's `str()`, so every message they print
// stays byte for byte what it always was.
func (n *Node) Str() string {
	if n.Kind() == String {
		return n.text
	}
	return n.Repr()
}

// StrOr is Str, or `fallback` when the value is absent. A value that is
// present but null is still `None`: only a missing key takes the fallback.
func (n *Node) StrOr(fallback string) string {
	if n == nil {
		return fallback
	}
	return n.Str()
}

// Repr renders the value as a literal -- a string quoted and escaped, a
// mapping as `{'key': value}` in document order -- in Python's `repr()`
// spelling, for the same reason Str follows `str()`.
func (n *Node) Repr() string {
	switch n.Kind() {
	case Null:
		return "None"
	case Bool:
		if n.value {
			return "True"
		}
		return "False"
	case Int:
		return n.text
	case Float:
		return FloatRepr(n.float)
	case String:
		return Quote(n.text)
	case Mapping:
		entries := make([]string, 0, len(n.pairs))
		for _, pair := range n.pairs {
			entries = append(entries, pair.Key.Repr()+": "+pair.Value.Repr())
		}
		return "{" + strings.Join(entries, ", ") + "}"
	case Sequence:
		entries := make([]string, 0, len(n.items))
		for _, item := range n.items {
			entries = append(entries, item.Repr())
		}
		return "[" + strings.Join(entries, ", ") + "]"
	}
	return "None"
}

// Quote renders a string as a quoted literal the way Python's `repr()` does:
// single quotes unless the string holds a single quote and no double one,
// backslash escapes for the quote, the backslash and the common control
// characters, and hexadecimal escapes for anything else that does not print.
func Quote(text string) string {
	quote := '\''
	if strings.ContainsRune(text, '\'') && !strings.ContainsRune(text, '"') {
		quote = '"'
	}
	var builder strings.Builder
	builder.WriteRune(quote)
	for _, character := range text {
		builder.WriteString(escapeRune(character, quote))
	}
	builder.WriteRune(quote)
	return builder.String()
}

func escapeRune(character, quote rune) string {
	const (
		asciiDelete = 0x7f
		latin1Last  = 0xff
		bmpLast     = 0xffff
	)
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
	case character <= latin1Last:
		return fmt.Sprintf(`\x%02x`, character)
	case character <= bmpLast:
		return fmt.Sprintf(`\u%04x`, character)
	}
	return fmt.Sprintf(`\U%08x`, character)
}

// FloatRepr renders a float in its shortest exact form, as Python's `repr()`
// does: `1.0`, `0.0001`, `1e-05`, `1e+16`, `inf`, `nan`.
func FloatRepr(value float64) string {
	switch {
	case math.IsInf(value, 1):
		return "inf"
	case math.IsInf(value, -1):
		return "-inf"
	case math.IsNaN(value):
		return "nan"
	}
	scientific := strconv.FormatFloat(value, 'e', -1, 64)
	sign := ""
	if strings.HasPrefix(scientific, "-") {
		sign, scientific = "-", scientific[1:]
	}
	mantissa, exponentText, _ := strings.Cut(scientific, "e")
	exponent, _ := strconv.Atoi(exponentText)
	digits := strings.Replace(mantissa, ".", "", 1)
	// The decimal point sits `point` digits into `digits`.
	point := exponent + 1
	if point <= fixedNotationLow || point > fixedNotationHigh {
		rest := ""
		if len(digits) > 1 {
			rest = "." + digits[1:]
		}
		exponentSign := "+"
		if exponent < 0 {
			exponentSign, exponent = "-", -exponent
		}
		return fmt.Sprintf("%s%s%se%s%02d", sign, digits[:1], rest, exponentSign, exponent)
	}
	switch {
	case point <= 0:
		return sign + "0." + strings.Repeat("0", -point) + digits
	case point >= len(digits):
		return sign + digits + strings.Repeat("0", point-len(digits)) + ".0"
	}
	return sign + digits[:point] + "." + digits[point:]
}
