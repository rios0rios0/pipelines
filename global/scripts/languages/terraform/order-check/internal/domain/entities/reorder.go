package entities

import (
	"slices"
	"strconv"
	"strings"
	"unicode"
)

// item is one reorderable unit: a block, with the trivia -- blank lines and
// attached comments -- between the previous block and it, so both travel
// together when reordered.
type item struct {
	block Block
	text  string
}

// splitRegion slices `source[start:end]` into the items of the blocks starting
// inside it and the suffix after the last. It answers false when the region
// has no block or the slices do not reproduce it byte for byte -- then the
// file must not be rewritten.
func splitRegion(source string, start, end int, blocks []Block) ([]item, string, bool) {
	var items []item
	cursor := start
	for _, block := range blocks {
		if block.Start < start || block.Start >= end {
			continue
		}
		items = append(items, item{block: block, text: slice(source, cursor, block.End)})
		cursor = block.End
	}
	if len(items) == 0 {
		return nil, "", false
	}
	suffix := slice(source, cursor, end)
	var rebuilt strings.Builder
	for _, piece := range items {
		rebuilt.WriteString(piece.text)
	}
	rebuilt.WriteString(suffix)
	if rebuilt.String() != slice(source, start, end) {
		return nil, "", false
	}
	return items, suffix, true
}

// joinRegion puts a region back together around reordered items.
func joinRegion(source string, start, end int, items []item, suffix string) string {
	var b strings.Builder
	b.WriteString(source[:start])
	for _, piece := range items {
		b.WriteString(piece.text)
	}
	b.WriteString(suffix)
	b.WriteString(source[min(end, len(source)):])
	return b.String()
}

// Reorder sorts every block of the region by `compare`, stably, and answers
// false when the region does not round-trip.
func Reorder(source string, start, end int, blocks []Block, compare func(a, b Block) int) (string, bool) {
	items, suffix, ok := splitRegion(source, start, end, blocks)
	if !ok {
		return "", false
	}
	slices.SortStableFunc(items, func(a, b item) int { return compare(a.block, b.block) })
	return joinRegion(source, start, end, items, suffix), true
}

// ReorderPinned sorts only the movable blocks, stably, into the slots movable
// blocks already held; every other block -- `tags`, a literal, a provider the
// ranking does not know -- keeps its position. False when the region does not
// round-trip.
func ReorderPinned(
	source string, start, end int, blocks []Block, movable func(Block) bool, compare func(a, b Block) int,
) (string, bool) {
	items, suffix, ok := splitRegion(source, start, end, blocks)
	if !ok {
		return "", false
	}
	return joinRegion(source, start, end, pinned(items, movable, compare), suffix), true
}

// pinned is `items` with the movable ones sorted among their own slots.
func pinned(items []item, movable func(Block) bool, compare func(a, b Block) int) []item {
	var slots []int
	var moving []item
	for index, piece := range items {
		if movable(piece.block) {
			slots = append(slots, index)
			moving = append(moving, piece)
		}
	}
	slices.SortStableFunc(moving, func(a, b item) int { return compare(a.block, b.block) })
	reordered := slices.Clone(items)
	for i, slot := range slots {
		reordered[slot] = moving[i]
	}
	return reordered
}

// Sorted is true when no key is greater than the one after it.
func Sorted[T any](keys []T, compare func(a, b T) int) bool {
	for i := 1; i < len(keys); i++ {
		if compare(keys[i-1], keys[i]) > 0 {
			return false
		}
	}
	return true
}

// Number is an environment layer's number -- the `NN` of `environments/NN_` --
// of any size, in any script's decimal digits, compared by value.
type Number struct {
	digits string
}

// unmappedDigits is the number given to a dependency with no layer number or
// an input fed by no known dependency: it sorts them after every real layer
// in their group.
const unmappedDigits = "9999"

// Unmapped is the number of a dependency whose layer is unknown.
func Unmapped() Number {
	return Number{digits: unmappedDigits}
}

// ParseNumber reads a run of decimal digits of any script as a number.
func ParseNumber(digits string) Number {
	var b strings.Builder
	for _, r := range digits {
		value := digitValue(r)
		if b.Len() == 0 && value == 0 {
			continue
		}
		b.WriteString(strconv.Itoa(value))
	}
	if b.Len() == 0 {
		return Number{digits: "0"}
	}
	return Number{digits: b.String()}
}

// decimalBase is the size of every run of decimal digits Unicode assigns.
const decimalBase = 10

// digitValue is the value of a decimal digit of any script. Unicode assigns
// decimal digits in contiguous runs of ten, zero first, so a digit's value is
// its distance from the start of the run of digits it belongs to, modulo ten.
func digitValue(r rune) int {
	start := r
	for start > 0 && unicode.IsDigit(start-1) {
		start--
	}
	return int(r-start) % decimalBase
}

// Compare orders two numbers by value.
func (n Number) Compare(other Number) int {
	if len(n.digits) != len(other.digits) {
		return len(n.digits) - len(other.digits)
	}
	return strings.Compare(n.digits, other.digits)
}

// minimumDigits is how many digits a number is shown with, at least.
const minimumDigits = 2

// String is the number with at least two digits: `03`, `12`, `9999`.
func (n Number) String() string {
	if len(n.digits) < minimumDigits {
		return "0" + n.digits
	}
	return n.digits
}
