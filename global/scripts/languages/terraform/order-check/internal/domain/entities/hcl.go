// Package entities holds the Terragrunt file-ordering standard: how the
// checker reads the blocks of a `.tf` / `.hcl` file as exact substrings, the
// rules each kind of file is held to, and the findings it reports.
package entities

import (
	"errors"
	"regexp"
	"strings"

	"github.com/rios0rios0/pipelines/global/scripts/languages/terraform/internal/text"
)

// ErrUnbalanced is a block whose braces never close: the file cannot be read
// as blocks at all, so the whole run stops rather than guess.
var ErrUnbalanced = errors.New("unbalanced braces")

var (
	heredocOpener = regexp.MustCompile(`^<<-?(["A-Za-z0-9_]+)`)
	inputsBlock   = regexp.MustCompile(`(?m)^inputs` + text.Space + `*=` + text.Space + `*\{`)
	inputKey      = regexp.MustCompile(`^[ \t]*([A-Za-z0-9_]+)` + text.Space + `*=` + text.Space + `*`)
)

// SkipNoncode is the offset just past the string, comment or heredoc that
// starts at `at`, or `at` itself when none does. It lets the brace and value
// scanners ignore a `{`, `}` or line break inside a `"`/`'` string, a `#` or
// `//` comment, a `/* */` comment or a `<<TAG` heredoc body -- so a brace in
// any of those is never mistaken for a structural one, which would cut a
// block short and corrupt a `--fix` reorder.
func SkipNoncode(source string, at int) int {
	switch current := source[at]; {
	case current == '"' || current == '\'':
		for end := at + 1; end < len(source); end++ {
			if source[end] == '\\' {
				end++
				continue
			}
			if source[end] == current {
				return end + 1
			}
		}
		return len(source)
	case current == '#' || strings.HasPrefix(source[at:], "//"):
		if newline := strings.IndexByte(source[at:], '\n'); newline >= 0 {
			return at + newline
		}
		return len(source)
	case strings.HasPrefix(source[at:], "/*"):
		if end := strings.Index(source[at+len("/*"):], "*/"); end >= 0 {
			return at + len("/*") + end + len("*/")
		}
		return len(source)
	case strings.HasPrefix(source[at:], "<<"):
		return skipHeredoc(source, at)
	default:
		return at
	}
}

// skipHeredoc is the offset of the line break ending a heredoc's terminator
// line, the end of `source` when it never ends, or `at` when no heredoc
// starts there.
func skipHeredoc(source string, at int) int {
	opener := heredocOpener.FindStringSubmatch(source[at:])
	if opener == nil {
		return at
	}
	tag := strings.Trim(opener[1], `"`)
	newline := strings.IndexByte(source[at:], '\n')
	if newline < 0 {
		return len(source)
	}
	body := at + newline + 1
	terminator := regexp.MustCompile(`(?m)^[ \t]*` + regexp.QuoteMeta(tag) + `[ \t]*$`).FindStringIndex(source[body:])
	if terminator == nil {
		return len(source)
	}
	end := body + terminator[1]
	if after := strings.IndexByte(source[end:], '\n'); after >= 0 {
		return end + after
	}
	return len(source)
}

// MatchingBrace is the offset of the `}` closing the `{` at `open`, ignoring
// braces in strings, comments and heredocs.
func MatchingBrace(source string, open int) (int, error) {
	depth := 0
	for at := open; at < len(source); {
		if next := SkipNoncode(source, at); next != at {
			at = next
			continue
		}
		switch source[at] {
		case '{':
			depth++
		case '}':
			depth--
			if depth == 0 {
				return at, nil
			}
		}
		at++
	}
	return 0, ErrUnbalanced
}

// Block is a top-level block captured as an exact substring of its file.
type Block struct {
	// Name is the block's first label.
	Name string
	// Start is the offset of its keyword, at column 0.
	Start int
	// End is just past its closing brace and the line break after it.
	End int
}

// TopLevelBlocks are the column-0 `keyword "<name>" ... {` blocks of a
// fmt-canonical file -- `variable`, `output`, `provider`, `dependency`, which
// `terraform fmt` and `terragrunt hcl format` anchor at column 0.
func TopLevelBlocks(source, keyword string) ([]Block, error) {
	pattern := regexp.MustCompile(`(?m)^` + regexp.QuoteMeta(keyword) + text.Space + `+"([^"]+)"[^\n{]*\{`)
	var blocks []Block
	for _, match := range pattern.FindAllStringSubmatchIndex(source, -1) {
		open := match[0] + strings.IndexByte(source[match[0]:], '{')
		closing, err := MatchingBrace(source, open)
		if err != nil {
			return nil, err
		}
		end := closing + 1
		if end < len(source) && source[end] == '\n' {
			end++
		}
		blocks = append(blocks, Block{Name: source[match[2]:match[3]], Start: match[0], End: end})
	}
	return blocks, nil
}

// InputsBody is the text between the braces of the top-level
// `inputs = { ... }` block, and false when the file has none.
func InputsBody(source string) (string, bool, error) {
	location := inputsBlock.FindStringIndex(source)
	if location == nil {
		return "", false, nil
	}
	open := location[0] + strings.IndexByte(source[location[0]:], '{')
	closing, err := MatchingBrace(source, open)
	if err != nil {
		return "", false, err
	}
	return source[open+1 : closing], true, nil
}

// ValueEnd is the offset just past the value that starts at `start`, its
// line break included: a one-line scalar, a value whose brackets span lines,
// or a heredoc -- a bracket or line break inside a string or comment never
// ending it early.
func ValueEnd(body string, start int) int {
	depth := 0
	for at := start; at < len(body); {
		if next := SkipNoncode(body, at); next != at {
			at = next
			continue
		}
		switch current := body[at]; {
		case strings.IndexByte("([{", current) >= 0:
			depth++
		case strings.IndexByte(")]}", current) >= 0:
			depth--
		case current == '\n' && depth == 0:
			return at + 1
		}
		at++
	}
	return len(body)
}

// Entry is one `key = value` of a map body, as an exact slice holding the
// trivia before it.
type Entry struct {
	Text  string
	Key   string
	Value string
}

// SplitEntries splits a `{ ... }` map body -- a terragrunt `inputs` -- into
// its entries and the text after the last one. Values are read balanced, so a
// `dependency.<name>.outputs` reference anywhere in a multi-line value belongs
// to its entry; concatenating every entry and the suffix reproduces `body`.
func SplitEntries(body string) ([]Entry, string) {
	var entries []Entry
	cursor := 0
	lineStart := true
	for at := 0; at < len(body); {
		if lineStart {
			if match := inputKey.FindStringSubmatchIndex(body[at:]); match != nil {
				valueStart := at + match[1]
				end := ValueEnd(body, valueStart)
				entries = append(entries, Entry{
					Text:  body[cursor:end],
					Key:   body[at+match[2] : at+match[3]],
					Value: body[valueStart:end],
				})
				cursor, at = end, end
				lineStart = end > 0 && body[end-1] == '\n'
				continue
			}
		}
		lineStart = body[at] == '\n'
		at++
	}
	return entries, body[cursor:]
}

// slice is `source[start:end]` read leniently: an empty string when the
// range is empty or reversed, either end clamped to the text.
func slice(source string, start, end int) string {
	start = max(0, min(start, len(source)))
	end = max(0, min(end, len(source)))
	if start >= end {
		return ""
	}
	return source[start:end]
}
