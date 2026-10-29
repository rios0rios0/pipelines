package entities

import (
	"regexp"

	"github.com/rios0rios0/pipelines/global/scripts/languages/terraform/internal/text"
)

var (
	// blockHeader is `<kind> ["label" ...] {`, matched against the SOURCE --
	// the mask blanks string contents, which would eat the labels -- and
	// accepted only when the same offset of the masked text is a real `{`.
	blockHeader = regexp.MustCompile(`^([A-Za-z_][A-Za-z0-9_-]*)((?:[ \t]+"[^"\n]*")*)[ \t]*\{`)
	blockLabel  = regexp.MustCompile(`"([^"\n]*)"`)
	// attributeName is `name =`, matched against the masked text; `==`, `=~`
	// and `=>` are not assignments, which is checked after the match.
	attributeName = regexp.MustCompile(`^([A-Za-z_][A-Za-z0-9_-]*)[ \t]*=`)
)

// Block is one block: its kind, labels, where its keyword starts, and the
// offsets of its braces.
type Block struct {
	Kind   string
	Labels []string
	Start  int
	Open   int
	Close  int
}

// Attribute is one `name = expression`, the expression's offsets.
type Attribute struct {
	Name  string
	Start int
	End   int
}

// Scanner walks the blocks and attributes of one masked source.
type Scanner struct {
	masked string
	source string
}

// NewScanner scans `source` through its mask.
func NewScanner(source, masked string) Scanner {
	return Scanner{masked: masked, source: source}
}

// Masked is the masked text the scanner reads.
func (s Scanner) Masked() string {
	return s.masked
}

// startsWord is true when a word -- a block kind or an attribute name --
// may start at `at`: a letter of any script, or `_`.
func (s Scanner) startsWord(at int) bool {
	r, _ := text.RuneAt(s.masked, at)
	return r == '_' || text.IsAlpha(r)
}

// skipWord steps past the word at `at`, never standing still.
func (s Scanner) skipWord(at, high int) int {
	for at < high {
		r, width := text.RuneAt(s.masked, at)
		if r != '_' && r != '-' && !text.IsAlnum(r) {
			break
		}
		at += width
	}
	return at
}

// header is the block whose header starts at `at`, if one does.
func (s Scanner) header(at, high int) (Block, bool) {
	match := blockHeader.FindStringSubmatchIndex(s.source[at:])
	if match == nil {
		return Block{}, false
	}
	end := at + match[1]
	if end > high || s.masked[end-1] != '{' {
		return Block{}, false
	}
	var labels []string
	for _, label := range blockLabel.FindAllStringSubmatch(s.source[at+match[4]:at+match[5]], -1) {
		labels = append(labels, label[1])
	}
	return Block{
		Kind:   s.source[at+match[2] : at+match[3]],
		Labels: labels,
		Start:  at,
		Open:   end - 1,
		Close:  matchBrace(s.masked, end-1, high),
	}, true
}

// Blocks are the blocks declared DIRECTLY in `[low, high)`, their bodies skipped.
func (s Scanner) Blocks(low, high int) []Block {
	var blocks []Block
	for at := low; at < high; {
		switch {
		case s.masked[at] == '{':
			at = matchBrace(s.masked, at, high) + 1
		case s.startsWord(at):
			if block, ok := s.header(at, high); ok {
				blocks = append(blocks, block)
				at = block.Close + 1
				continue
			}
			at = s.skipWord(at, high)
		default:
			at++
		}
	}
	return blocks
}

// BlocksDeep are every block in `[low, high)`, each followed by its own
// nested blocks.
func (s Scanner) BlocksDeep(low, high int) []Block {
	var blocks []Block
	for _, block := range s.Blocks(low, high) {
		blocks = append(blocks, block)
		blocks = append(blocks, s.BlocksDeep(block.Open+1, block.Close)...)
	}
	return blocks
}

// expressionEnd is where the expression starting at `start` ends: at a
// closing bracket it did not open, or at a line break outside brackets.
//
// Balanced, not a pattern: a non-greedy `assert { ... }` pattern stops at the
// first nested `}` and loses every reference after it -- and real conditions
// are full of `[for p in x.y : p if ...]`.
func (s Scanner) expressionEnd(start, high int) int {
	depth := 0
	at := start
	for ; at < high; at++ {
		switch current := s.masked[at]; {
		case current == '(' || current == '[' || current == '{':
			depth++
		case current == ')' || current == ']' || current == '}':
			if depth == 0 {
				return at
			}
			depth--
		case current == '\n' && depth == 0:
			return at
		}
	}
	return at
}

// attribute reads what starts at `at`: a nested block (skipped whole), an
// attribute, or a bare word (stepped over); and where to resume.
func (s Scanner) attribute(at, high int) (Attribute, bool, int) {
	if block, ok := s.header(at, high); ok {
		return Attribute{}, false, block.Close + 1
	}
	if match := attributeName.FindStringSubmatchIndex(s.masked[at:]); match != nil {
		assign := at + match[1]
		if assign >= len(s.masked) || !isComparison(s.masked[assign]) {
			start := assign
			for start < len(s.masked) && (s.masked[start] == ' ' || s.masked[start] == '\t') {
				start++
			}
			end := s.expressionEnd(start, high)
			return Attribute{Name: s.masked[at+match[2] : at+match[3]], Start: start, End: end}, true, max(end, start+1)
		}
	}
	return Attribute{}, false, s.skipWord(at, high)
}

// isComparison is the character that makes a `=` part of `==`, `=~` or `=>`.
func isComparison(next byte) bool {
	return next == '=' || next == '~' || next == '>'
}

// Attributes are the attributes declared DIRECTLY in `[low, high)`.
func (s Scanner) Attributes(low, high int) []Attribute {
	var attributes []Attribute
	for at := low; at < high; {
		switch {
		case s.masked[at] == '{':
			at = matchBrace(s.masked, at, high) + 1
		case s.startsWord(at):
			attribute, ok, next := s.attribute(at, high)
			if ok {
				attributes = append(attributes, attribute)
			}
			at = next
		default:
			at++
		}
	}
	return attributes
}

// AttributesDeep are the attributes of `[low, high)`, then those of each
// block in it, recursively.
func (s Scanner) AttributesDeep(low, high int) []Attribute {
	attributes := s.Attributes(low, high)
	for _, block := range s.Blocks(low, high) {
		attributes = append(attributes, s.AttributesDeep(block.Open+1, block.Close)...)
	}
	return attributes
}

// Expression is the masked expression of the first attribute `name` in
// `[low, high)`, and false when there is none.
func (s Scanner) Expression(low, high int, name string) (string, bool) {
	for _, attribute := range s.Attributes(low, high) {
		if attribute.Name == name {
			return s.masked[attribute.Start:attribute.End], true
		}
	}
	return "", false
}
