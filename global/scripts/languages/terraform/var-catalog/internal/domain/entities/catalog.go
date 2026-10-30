// Package entities holds what the shared-variable generator knows about a
// repository: the catalog of canonical `variable` bodies, which variables a
// stack uses and declares, and the file it generates for a stack.
package entities

import (
	"strings"

	"github.com/rios0rios0/pipelines/global/scripts/languages/terraform/internal/text"
)

// Catalog maps each catalogued variable to its one canonical declaration.
type Catalog map[string]string

// ParseCatalog reads every `name = <<-TAG ... TAG` entry of a catalog file.
//
// An entry starts on a line of its own: whitespace (blank lines included), the
// name, `=`, `<<` or `<<-` and a tag, then the end of that line. Its body runs
// to the first later line holding the tag alone, give or take whitespace, and
// is dedented the way `<<-` dedents. A later entry for the same name replaces
// an earlier one. Anything that is not such an entry -- the `locals {` around
// them, comments, a malformed opener -- is skipped, never an error.
func ParseCatalog(source string) Catalog {
	catalog := Catalog{}
	for start := 0; start <= len(source); {
		if start > 0 && source[start-1] != '\n' {
			start = nextLineStart(source, start)
			continue
		}
		entry, end, ok := matchEntry(source, start)
		if !ok {
			start = nextLineStart(source, start)
			continue
		}
		catalog[entry.name] = Dedent(strings.TrimRight(entry.body, "\n"))
		start = end
	}
	return catalog
}

// entry is one catalogued declaration as written.
type entry struct {
	name string
	body string
}

// nextLineStart is where the line after the one holding `at` starts, or just
// past the end when there is none.
func nextLineStart(source string, at int) int {
	if newline := strings.IndexByte(source[at:], '\n'); newline >= 0 {
		return at + newline + 1
	}
	return len(source) + 1
}

// span is the offset just past the run of bytes from `at` that `keep` accepts.
func span(source string, at int, keep func(byte) bool) int {
	for at < len(source) && keep(source[at]) {
		at++
	}
	return at
}

func isNameByte(b byte) bool {
	return isTagByte(b) || b == '-'
}

func isTagByte(b byte) bool {
	return b >= 'a' && b <= 'z' || b >= 'A' && b <= 'Z' || b >= '0' && b <= '9' || b == '_'
}

// matchEntry reads the entry whose line starts at `start`, and where scanning
// resumes after it.
func matchEntry(source string, start int) (entry, int, bool) {
	at := text.SpanSpace(source, start)
	nameEnd := span(source, at, isNameByte)
	if nameEnd == at {
		return entry{}, 0, false
	}
	name := source[at:nameEnd]
	at = text.SpanSpace(source, nameEnd)
	if !strings.HasPrefix(source[at:], "=") {
		return entry{}, 0, false
	}
	at = text.SpanSpace(source, at+1)
	if !strings.HasPrefix(source[at:], "<<") {
		return entry{}, 0, false
	}
	at += len("<<")
	if strings.HasPrefix(source[at:], "-") {
		at++
	}
	tagEnd := span(source, at, isTagByte)
	if tagEnd == at {
		return entry{}, 0, false
	}
	tag := source[at:tagEnd]
	// The opener's line ends at a line break inside the whitespace after the
	// tag; the latest one is tried first, so blank lines right after the
	// opener are not part of the body.
	gapEnd := text.SpanSpace(source, tagEnd)
	for newline := gapEnd - 1; newline >= tagEnd; newline-- {
		if source[newline] != '\n' {
			continue
		}
		bodyStart := newline + 1
		if bodyEnd, end, found := findTerminator(source, bodyStart, tag); found {
			return entry{name: name, body: source[bodyStart:bodyEnd]}, end, true
		}
	}
	return entry{}, 0, false
}

// findTerminator finds the first line from `from` on that holds `tag` alone,
// give or take whitespace: where the body ends, and where scanning resumes --
// at the last line break of the whitespace after the tag, or the end.
func findTerminator(source string, from int, tag string) (int, int, bool) {
	for line := from; line <= len(source); {
		at := text.SpanSpace(source, line)
		if strings.HasPrefix(source[at:], tag) {
			after := at + len(tag)
			gapEnd := text.SpanSpace(source, after)
			if gapEnd == len(source) {
				return line, len(source), true
			}
			for end := gapEnd - 1; end >= after; end-- {
				if source[end] == '\n' {
					return line, end, true
				}
			}
		}
		newline := strings.IndexByte(source[line:], '\n')
		if newline < 0 {
			break
		}
		line += newline + 1
	}
	return 0, 0, false
}

// Dedent strips the indentation every non-blank line shares, the way `<<-`
// does, and empties blank lines.
//
// Load-bearing rather than cosmetic: a `variable` block emitted with leading
// whitespace is still valid Terraform, but it is no longer a TOP-LEVEL block
// to a scanner that anchors on column 0 -- which is exactly how the sibling
// order-check collects declared variable names. Indented output therefore
// parses fine and then gets reported as a dead input for every stack, a
// failure whose message points nowhere near its cause.
func Dedent(block string) string {
	lines := strings.Split(block, "\n")
	pad := -1
	for _, line := range lines {
		if text.Strip(line) == "" {
			continue
		}
		width := text.RuneCount(line) - text.RuneCount(text.LStrip(line))
		if pad < 0 || width < pad {
			pad = width
		}
	}
	pad = max(pad, 0)
	for i, line := range lines {
		if text.Strip(line) == "" {
			lines[i] = ""
			continue
		}
		lines[i] = text.DropRunes(line, pad)
	}
	return strings.Join(lines, "\n")
}
