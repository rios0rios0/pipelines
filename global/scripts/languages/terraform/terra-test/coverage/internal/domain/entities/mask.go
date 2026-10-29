// Package entities holds what the coverage report knows about a Terraform
// module: its source with comments and literals masked, the blocks and
// attributes in it, the addresses an expression references, and which
// declared blocks an executed assertion reaches.
package entities

import (
	"regexp"
	"strings"

	"github.com/rios0rios0/pipelines/global/scripts/languages/terraform/internal/text"
)

// heredocOpener is `<<TAG` or `<<-TAG` ending its line.
var heredocOpener = regexp.MustCompile(`^<<-?([A-Za-z_][A-Za-z0-9_]*)[ \t]*\r?\n`)

// Mask is `source` with comments and literal string bodies blanked to
// spaces, every byte at its offset and every line break kept, so an offset
// into the masked text is the same offset into the source and needs no
// translation to a line number.
//
// Everything downstream reads the MASKED text. That is the load-bearing part
// of this report, and the sibling `var-catalog` learned it the expensive way:
// a naive scan treats the `//` in `"https://api.example/${var.env}"` as a
// comment start and loses the interpolation after it, while a comment that
// merely MENTIONS `aws_s3_bucket.foo` invents a reference that does not
// exist. A `${...}` interpolation is kept as code: a traversal inside one is a
// real reference.
func Mask(source string) string {
	out := []byte(source)
	for at := 0; at < len(source); {
		switch {
		case source[at] == '#' || strings.HasPrefix(source[at:], "//"):
			at = maskLineComment(out, source, at)
		case strings.HasPrefix(source[at:], "/*"):
			at = maskBlockComment(out, source, at)
		case source[at] == '<' && heredocOpener.MatchString(source[at:]):
			at = maskHeredoc(out, source, at)
		case source[at] == '"':
			end := stringEnd(source, at)
			maskLiteral(out, source, at+1, min(end, len(source)))
			at = min(end+1, len(source))
		default:
			at++
		}
	}
	return string(out)
}

// blank turns `[low, high)` into spaces, the line breaks kept when `keepLines`.
func blank(out []byte, low, high int, keepLines bool) {
	for k := low; k < high; k++ {
		if !keepLines || out[k] != '\n' {
			out[k] = ' '
		}
	}
}

// maskLineComment blanks a `#` or `//` comment up to its line break.
func maskLineComment(out []byte, source string, at int) int {
	end := strings.IndexByte(source[at:], '\n')
	if end < 0 {
		end = len(source)
	} else {
		end += at
	}
	blank(out, at, end, false)
	return end
}

// maskBlockComment blanks a `/* ... */` comment, which may span lines.
func maskBlockComment(out []byte, source string, at int) int {
	end := strings.Index(source[at+len("/*"):], "*/")
	if end < 0 {
		end = len(source)
	} else {
		end += at + len("/*") + len("*/")
	}
	blank(out, at, end, true)
	return end
}

// maskHeredoc blanks a heredoc, keeping the interpolations of its body. The
// opener and the terminator stand in as a bracket pair: a heredoc is ONE
// attribute value spanning many lines, and the expression scanner stops at
// the first line break seen outside brackets -- without the pair,
// `policy = <<-EOT ... EOT` would read as an empty value and every reference
// interpolated in the body would be lost. Brackets are invisible to the block
// scanner, which counts only braces.
func maskHeredoc(out []byte, source string, at int) int {
	opener := heredocOpener.FindStringSubmatch(source[at:])
	body := at + len(opener[0])
	terminatorStart, terminatorEnd := heredocTerminator(source, opener[1], body)
	blank(out, at, body, true)
	maskLiteral(out, source, body, terminatorStart)
	blank(out, terminatorStart, terminatorEnd, false)
	out[at] = '('
	if terminatorEnd > terminatorStart {
		out[terminatorEnd-1] = ')'
	}
	return terminatorEnd
}

// heredocTerminator is where the line holding the tag alone starts and ends,
// or the end of `source` twice when the heredoc never ends.
func heredocTerminator(source, tag string, body int) (int, int) {
	for line := body; line < len(source); {
		end := strings.IndexByte(source[line:], '\n')
		lineEnd := len(source)
		if end >= 0 {
			lineEnd = line + end
		}
		if text.Strip(source[line:lineEnd]) == tag {
			return line, lineEnd
		}
		if end < 0 {
			break
		}
		line = lineEnd + 1
	}
	return len(source), len(source)
}

// maskLiteral blanks a string or heredoc body in `[low, high)` but KEEPS its
// `${...}` and `%{...}` contents, blanking only their delimiters so they
// cannot change the brace depth the block scanner sees. An interpolation
// that never closes keeps the rest of the literal as code rather than
// silently swallowing it.
func maskLiteral(out []byte, source string, low, high int) {
	for k := low; k < high; {
		if strings.HasPrefix(source[k:], "${") || strings.HasPrefix(source[k:], "%{") {
			closing := matchBrace(source, k+1, high)
			out[k], out[k+1] = ' ', ' '
			if closing >= high {
				return
			}
			out[closing] = ' '
			k = closing + 1
			continue
		}
		if source[k] != '\n' {
			out[k] = ' '
		}
		k++
	}
}

// stringEnd is the offset of the quote closing the literal opened at `at`,
// or of its line break, or past the end.
//
// A quote inside an open `${...}` does NOT end the literal: interpolations
// routinely carry their own strings, and `"${join(",", [aws_s3_bucket.b.id])}"`
// is the common shape. Ending at the first quote would close the literal on
// the separator and lose every reference after it. Two known limits, both
// over-crediting and rare: a string nested inside an interpolation is kept as
// code, and `$${`, the escape for a literal `${`, reads as an interpolation.
func stringEnd(source string, at int) int {
	end := at + 1
	interpolation := 0
	for end < len(source) {
		current := source[end]
		switch {
		case current == '\\':
			end += 2
			continue
		case current == '\n':
			return end
		case (current == '$' || current == '%') && end+1 < len(source) && source[end+1] == '{':
			interpolation++
			end += 2
			continue
		case interpolation > 0:
			interpolation += braceDelta(current)
		case current == '"':
			return end
		}
		end++
	}
	return end
}

// braceDelta is how one character moves brace depth.
func braceDelta(character byte) int {
	switch character {
	case '{':
		return 1
	case '}':
		return -1
	default:
		return 0
	}
}

// matchBrace is the offset of the `}` closing the `{` at `open`, braces
// counted raw, or `high - 1` when it does not close before `high`.
func matchBrace(source string, open, high int) int {
	depth := 0
	for k := open; k < high; k++ {
		switch source[k] {
		case '{':
			depth++
		case '}':
			depth--
			if depth == 0 {
				return k
			}
		}
	}
	return high - 1
}
