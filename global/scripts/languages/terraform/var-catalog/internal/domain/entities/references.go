package entities

import (
	"regexp"
	"strings"

	"github.com/rios0rios0/pipelines/global/scripts/languages/terraform/internal/text"
)

// declaration is `variable "name" {` at column 0 -- the declaration form, not
// a `var.` use.
var declaration = regexp.MustCompile(`(?m)^variable` + text.Space + `+"([A-Za-z0-9_-]+)"` + text.Space + `*\{`)

// StripComments removes `#`, `//` and `/* */` comments, respecting string
// literals.
//
// Load-bearing, not tidiness: these files are comment-dense, and a comment
// that merely MENTIONS `var.tags` would otherwise resurrect a declaration the
// stack no longer uses -- reintroducing the dead code this tool removes.
//
// String awareness is equally load-bearing, and was learned the hard way: a
// naive scan treats the `//` in `"https://api.example/..."` as a comment
// start, truncates the line, and loses the `${var.environment}` interpolation
// after it. The stack then gets no declaration for a variable it genuinely
// uses. That failure is at least loud -- `terraform validate` reports an
// undeclared input variable -- but it should not happen at all.
func StripComments(source string) string {
	inBlock := false
	lines := strings.Split(source, "\n")
	for index, line := range lines {
		lines[index], inBlock = stripLine(line, inBlock)
	}
	return strings.Join(lines, "\n")
}

// escapeWidth is a backslash and the character it escapes.
const escapeWidth = 2

// stripLine is one line without its comments, and whether a block comment is
// still open at its end. A string is tracked per line: a quote opens or closes
// one, a backslash inside one escapes the next character.
func stripLine(line string, inBlock bool) (string, bool) {
	var kept strings.Builder
	inString := false
	for i := 0; i < len(line); {
		if inBlock {
			// A block comment ends only outside a string; a `*/` inside one
			// cannot close it, because it was never opened there.
			if strings.HasPrefix(line[i:], "*/") {
				inBlock = false
				i += len("*/")
				continue
			}
			i++
			continue
		}
		current := line[i]
		if current == '\\' && inString {
			kept.WriteString(line[i:min(i+escapeWidth, len(line))])
			i += escapeWidth
			continue
		}
		if current == '"' {
			inString = !inString
		} else if !inString {
			// Block comments are handled HERE, in the same string-aware pass as
			// `#` and `//`, not by a regex beforehand. A pre-pass would delete a
			// `/* */` sequence sitting inside a quoted string and take any
			// `var.<name>` after it on the line with it.
			if strings.HasPrefix(line[i:], "/*") {
				inBlock = true
				i += len("/*")
				continue
			}
			if current == '#' || strings.HasPrefix(line[i:], "//") {
				break
			}
		}
		kept.WriteByte(current)
		i++
	}
	return kept.String(), inBlock
}

// UsedVariables are the names `source` reads as `var.<name>`, stopping at the
// first character that cannot be in a name, so `var.placement.cloud` uses
// `placement`. A `var.` right after a letter, digit or `_` is part of a longer
// word and not a use.
func UsedVariables(source string) []string {
	const prefix = "var."
	var names []string
	for at := 0; at < len(source); {
		start := at + len(prefix)
		if !strings.HasPrefix(source[at:], prefix) || !text.WordBoundaryBefore(source, at) ||
			start >= len(source) || !isNameStart(source[start]) {
			at++
			continue
		}
		end := span(source, start+1, isTagByte)
		names = append(names, source[start:end])
		at = end
	}
	return names
}

func isNameStart(b byte) bool {
	return b >= 'a' && b <= 'z' || b >= 'A' && b <= 'Z' || b == '_'
}

// DeclaredVariables are the names `source` declares with a column-0
// `variable "<name>" {`.
func DeclaredVariables(source string) []string {
	var names []string
	for _, match := range declaration.FindAllStringSubmatch(source, -1) {
		names = append(names, match[1])
	}
	return names
}
