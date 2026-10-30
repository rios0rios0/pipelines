// Package text is how the Terraform helpers read, classify and write source
// text, in one place, so the four of them agree on what a file says.
//
// They were Python scripts, and their outputs -- reports CI publishes, files
// developers commit -- were shaped by Python's text model: a file is decoded
// as UTF-8 with its line endings normalised to `\n`, "whitespace" and "a word
// character" are Unicode classes, and `strip()` removes Unicode whitespace.
// Reproducing those rules here keeps every report byte for byte what it was.
// A rule that looks over-careful for Terraform -- a no-break space counting as
// whitespace, a lone carriage return counting as a line break -- is kept
// because changing it would change what a committed file or a report says.
package text

import (
	"errors"
	"fmt"
	"os"
	"strings"
	"unicode"
	"unicode/utf8"
)

// ErrInvalidUTF8 is a file that is not UTF-8, which every helper but the
// coverage report refuses to guess at.
var ErrInvalidUTF8 = errors.New("is not valid UTF-8")

// NewFileMode and NewDirMode are the permissions a created file or directory
// asks for before the umask, as any editor or `mkdir` would: generated files
// are source the user commits, and reports are read by later CI steps.
const (
	NewFileMode os.FileMode = 0o666
	NewDirMode  os.FileMode = 0o777
)

// Space is [IsSpace] as a regular-expression character class, for the
// patterns that match whitespace: `variable` + Space + `+"`.
const Space = `[\t-\r\x{1c}-\x{20}\x{85}\x{a0}\x{1680}\x{2000}-\x{200a}\x{2028}\x{2029}\x{202f}\x{205f}\x{3000}]`

// IsSpace is the whitespace every helper strips, splits and skips: the
// characters Unicode puts in a space separator category or gives a whitespace
// bidirectional class, plus the ASCII information separators. The set is
// spelled out rather than taken from [unicode.IsSpace] because that one leaves
// out U+001C..U+001F, which these tools have always treated as whitespace.
func IsSpace(r rune) bool {
	if r < utf8.RuneSelf {
		return r >= '\t' && r <= '\r' || r >= '\x1c' && r <= ' '
	}
	return strings.ContainsRune(otherSpaces, r)
}

// otherSpaces are the whitespace characters beyond ASCII.
const otherSpaces = "\u0085\u00a0\u1680\u2000\u2001\u2002\u2003\u2004\u2005\u2006\u2007\u2008\u2009\u200a" +
	"\u2028\u2029\u202f\u205f\u3000"

// IsAlpha is a letter, in any script.
func IsAlpha(r rune) bool {
	return unicode.IsLetter(r)
}

// IsAlnum is a letter or a number, in any script.
func IsAlnum(r rune) bool {
	return unicode.IsLetter(r) || unicode.IsNumber(r)
}

// IsWord is a character a word is made of: a letter, a number or `_`. A
// reference such as `var.name` only counts where the character before it is
// not one, so `myvar.name` is not a use of `var.name`.
func IsWord(r rune) bool {
	return r == '_' || IsAlnum(r)
}

// RuneAt is the character starting at byte `i` of `s` and its width; a byte
// that starts no valid character reads as [utf8.RuneError] of width one.
func RuneAt(s string, i int) (rune, int) {
	return utf8.DecodeRuneInString(s[i:])
}

// RuneBefore is the character ending at byte `i` of `s`, and false at the
// start of `s`.
func RuneBefore(s string, i int) (rune, bool) {
	if i <= 0 {
		return 0, false
	}
	r, _ := utf8.DecodeLastRuneInString(s[:i])
	return r, true
}

// WordBoundaryBefore is true when a word may start at byte `i`: at the start
// of `s`, or after a character that is not a word character.
func WordBoundaryBefore(s string, i int) bool {
	previous, ok := RuneBefore(s, i)
	return !ok || !IsWord(previous)
}

// SpanSpace is the byte offset just past the run of whitespace starting at
// byte `i`.
func SpanSpace(s string, i int) int {
	for i < len(s) {
		r, width := RuneAt(s, i)
		if !IsSpace(r) {
			break
		}
		i += width
	}
	return i
}

// Strip removes leading and trailing whitespace.
func Strip(s string) string {
	return strings.TrimFunc(s, IsSpace)
}

// LStrip removes leading whitespace.
func LStrip(s string) string {
	return strings.TrimLeftFunc(s, IsSpace)
}

// RStrip removes trailing whitespace.
func RStrip(s string) string {
	return strings.TrimRightFunc(s, IsSpace)
}

// StripChars removes, from both ends, every character listed in `chars`.
func StripChars(s, chars string) string {
	return strings.Trim(s, chars)
}

// IsLineBreak is a character that ends a line when text is split into lines:
// the ASCII line breaks, the ASCII separators that end a record, and the
// Unicode line and paragraph separators.
func IsLineBreak(r rune) bool {
	return strings.ContainsRune(lineBreaks, r)
}

// lineBreaks are the characters [IsLineBreak] accepts.
const lineBreaks = "\n\v\f\r\x1c\x1d\x1e\u0085\u2028\u2029"

// FirstLine is `s` up to its first line break.
func FirstLine(s string) string {
	if end := strings.IndexFunc(s, IsLineBreak); end >= 0 {
		return s[:end]
	}
	return s
}

// RuneCount is the number of characters in `s`.
func RuneCount(s string) int {
	return utf8.RuneCountInString(s)
}

// DropRunes is `s` without its first `n` characters.
func DropRunes(s string, n int) string {
	for n > 0 && s != "" {
		_, width := utf8.DecodeRuneInString(s)
		s = s[width:]
		n--
	}
	return s
}

// Slice is the characters of `s` from index `start` up to, not including,
// index `end`, counted in characters; a negative `end` counts from the end. An
// index past either end is clamped and an empty range is an empty string, so
// a malformed type such as `list(` slices to nothing instead of failing.
func Slice(s string, start, end int) string {
	runes := []rune(s)
	if end < 0 {
		end += len(runes)
	}
	start = max(0, min(start, len(runes)))
	end = max(0, min(end, len(runes)))
	if start >= end {
		return ""
	}
	return string(runes[start:end])
}

// Normalise turns every line ending into `\n`: `\r\n` and a lone `\r` alike.
func Normalise(s string) string {
	if !strings.Contains(s, "\r") {
		return s
	}
	return strings.ReplaceAll(strings.ReplaceAll(s, "\r\n", "\n"), "\r", "\n")
}

// ReadStrict reads a file as UTF-8 with its line endings normalised, refusing
// one that is not UTF-8.
func ReadStrict(path string) (string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	if !utf8.Valid(data) {
		return "", fmt.Errorf("%s %w", path, ErrInvalidUTF8)
	}
	return Normalise(string(data)), nil
}

// ReadReplacing reads a file as UTF-8 with its line endings normalised, every
// run of bytes that is not UTF-8 replaced by U+FFFD. Used where an unreadable
// character must cost that character, never the whole file: U+FFFD is neither
// a letter, a space nor punctuation any scanner looks for, so the
// replacement cannot change what the rest of the file is read as.
func ReadReplacing(path string) (string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	return Normalise(strings.ToValidUTF8(string(data), string(utf8.RuneError))), nil
}

// Write replaces a file's contents, creating it if needed.
func Write(path, content string) error {
	return os.WriteFile(path, []byte(content), NewFileMode)
}

// EscapeXML escapes `&`, `<` and `>`. Quotes are NOT escaped: the reports have
// always been written this way, and their readers compare them byte for byte.
func EscapeXML(s string) string {
	return strings.NewReplacer("&", "&amp;", "<", "&lt;", ">", "&gt;").Replace(s)
}

// reprQuote picks the quote a string is shown in: single, unless it holds a
// single quote and no double quote.
func reprQuote(s string) byte {
	if strings.ContainsRune(s, '\'') && !strings.ContainsRune(s, '"') {
		return '"'
	}
	return '\''
}

// reprEscapes are the characters shown by a short escape.
func reprEscapes() map[rune]string {
	return map[rune]string{'\\': `\\`, '\t': `\t`, '\n': `\n`, '\r': `\r`}
}

// latin1Limit and bmpLimit are where an escaped character needs four, then
// eight, hexadecimal digits instead of two.
const (
	latin1Limit = 0x100
	bmpLimit    = 0x10000
)

// Repr is how a name is quoted in a finding: in quotes, with a backslash, a
// tab, a line break or an unprintable character escaped, so a provider named
// with a stray newline is still legible on one line.
func Repr(s string) string {
	quote := reprQuote(s)
	escapes := reprEscapes()
	var b strings.Builder
	b.WriteByte(quote)
	for _, r := range s {
		switch escaped, ok := escapes[r]; {
		case ok:
			b.WriteString(escaped)
		case r == rune(quote):
			b.WriteByte('\\')
			b.WriteByte(quote)
		case unicode.IsPrint(r):
			b.WriteRune(r)
		case r < latin1Limit:
			fmt.Fprintf(&b, `\x%02x`, r)
		case r < bmpLimit:
			fmt.Fprintf(&b, `\u%04x`, r)
		default:
			fmt.Fprintf(&b, `\U%08x`, r)
		}
	}
	b.WriteByte(quote)
	return b.String()
}

// ReprList shows names the way a finding lists them: `['a', 'b']`.
func ReprList(items []string) string {
	quoted := make([]string, len(items))
	for i, item := range items {
		quoted[i] = Repr(item)
	}
	return "[" + strings.Join(quoted, ", ") + "]"
}
