package entities

import (
	"regexp"
	"slices"
	"strings"

	"github.com/rios0rios0/pipelines/global/scripts/languages/terraform/internal/text"
)

var (
	moduleDeclaration   = regexp.MustCompile(`(?m)^module` + text.Space + `+"([^"]+)"` + text.Space + `*\{`)
	resourceDeclaration = regexp.MustCompile(
		`(?m)^resource` + text.Space + `+"([^"]+)"` + text.Space + `+"([^"]+)"` + text.Space + `*\{`,
	)
)

// notResourceTypes are the prefixes of `x.y` that are never a resource.
func notResourceTypes() []string {
	return []string{"var", "local", "module", "data", "each", "count", "self", "path", "terraform"}
}

// MainPositions ranks every `module.<name>` and `<type>.<name>` the stack's
// `main*.tf` files declare: `main.tf` first, then the other `main*.tf` by
// name, and within a file by position -- the order a reader meets them in.
// `mains` are the file names and texts, already in that order.
func MainPositions(mains []string) map[string]int {
	positions := map[string]int{}
	for _, source := range mains {
		type declaration struct {
			offset int
			token  string
		}
		var declarations []declaration
		for _, match := range moduleDeclaration.FindAllStringSubmatchIndex(source, -1) {
			declarations = append(declarations, declaration{match[0], "module." + source[match[2]:match[3]]})
		}
		for _, match := range resourceDeclaration.FindAllStringSubmatchIndex(source, -1) {
			declarations = append(declarations,
				declaration{match[0], source[match[2]:match[3]] + "." + source[match[4]:match[5]]})
		}
		slices.SortFunc(declarations, func(a, b declaration) int {
			if a.offset != b.offset {
				return a.offset - b.offset
			}
			return strings.Compare(a.token, b.token)
		})
		for _, found := range declarations {
			if _, seen := positions[found.token]; !seen {
				positions[found.token] = len(positions)
			}
		}
	}
	return positions
}

// SortMains orders `main*.tf` file names: `main.tf` first, then by name.
func SortMains(names []string) {
	slices.SortFunc(names, func(a, b string) int {
		aMain, bMain := a == "main.tf", b == "main.tf"
		if aMain != bMain {
			if aMain {
				return -1
			}
			return 1
		}
		return strings.Compare(a, b)
	})
}

// anchor is the position of the first module or resource an output's text
// references, and false when it references none the positions know. The
// first `module.<name>` counts, then any earlier-placed `<type>.<name>`.
func anchor(output string, positions map[string]int) (int, bool) {
	best, offset, found := 0, -1, false
	if at, name, ok := moduleReference(output); ok {
		if position, known := positions["module."+name]; known {
			best, offset, found = position, at, true
		}
	}
	for _, reference := range resourceReferences(output) {
		if slices.Contains(notResourceTypes(), reference.kind) {
			continue
		}
		position, known := positions[reference.kind+"."+reference.name]
		if known && (offset < 0 || reference.offset < offset) {
			best, offset, found = position, reference.offset, true
		}
	}
	return best, found
}

// moduleReference is the first `module.<name>` that starts a word.
func moduleReference(source string) (int, string, bool) {
	const prefix = "module."
	for at := strings.Index(source, prefix); at >= 0; {
		nameEnd := spanName(source, at+len(prefix))
		if text.WordBoundaryBefore(source, at) && nameEnd > at+len(prefix) {
			return at, source[at+len(prefix) : nameEnd], true
		}
		next := strings.Index(source[at+1:], prefix)
		if next < 0 {
			break
		}
		at += 1 + next
	}
	return 0, "", false
}

// reference is one `<type>.<name>` and where it starts.
type reference struct {
	offset int
	kind   string
	name   string
}

// resourceReferences are the `<type>.<name>` that start a word, left to
// right and not overlapping: a lowercase type of two or more characters, a
// dot, a name.
func resourceReferences(source string) []reference {
	var references []reference
	for at := 0; at < len(source); {
		if !isLower(source[at]) || !text.WordBoundaryBefore(source, at) {
			at++
			continue
		}
		typeEnd := at + 1
		for typeEnd < len(source) && (isLower(source[typeEnd]) || isDigit(source[typeEnd]) || source[typeEnd] == '_') {
			typeEnd++
		}
		nameEnd := spanName(source, typeEnd+1)
		if typeEnd == at+1 || typeEnd >= len(source) || source[typeEnd] != '.' || nameEnd == typeEnd+1 {
			at++
			continue
		}
		references = append(
			references,
			reference{offset: at, kind: source[at:typeEnd], name: source[typeEnd+1 : nameEnd]},
		)
		at = nameEnd
	}
	return references
}

// spanName is the offset past the `[A-Za-z0-9_]` run starting at `at`.
func spanName(source string, at int) int {
	for at < len(source) && (isLower(source[at]) || source[at] >= 'A' && source[at] <= 'Z' ||
		isDigit(source[at]) || source[at] == '_') {
		at++
	}
	return at
}

func isLower(b byte) bool {
	return b >= 'a' && b <= 'z'
}

func isDigit(b byte) bool {
	return b >= '0' && b <= '9'
}

// CheckOutputs holds a stack's `outputs.tf` to rule E: outputs follow the
// declaration order of the first module or resource each references in
// `main*.tf`. Only outputs that reference one are constrained; one that only
// passes a variable or local through rides along with the output before it
// when fixed, rather than jumping around. With `fix` it returns the rewritten
// text and true when it rewrote it. `positions` are read only once the file
// has two outputs to order.
func CheckOutputs(
	source, path string, positions func() (map[string]int, error), fix bool,
) ([]Finding, string, bool, error) {
	blocks, err := TopLevelBlocks(source, "output")
	if err != nil || len(blocks) < minimumOutputs {
		return nil, source, false, err
	}
	declared, err := positions()
	if err != nil || len(declared) == 0 {
		return nil, source, false, err
	}
	return orderOutputs(source, path, blocks, declared, fix)
}

// minimumOutputs is the fewest outputs that have an order to check.
const minimumOutputs = 2

// orderOutputs is rule E once the outputs and the declaration positions are known.
func orderOutputs(
	source, path string,
	blocks []Block,
	positions map[string]int,
	fix bool,
) ([]Finding, string, bool, error) {
	effective := make([]int, len(blocks))
	running := -1
	var anchored []labelled[int]
	for i, block := range blocks {
		if position, found := anchor(source[block.Start:block.End], positions); found {
			running = position
			anchored = append(anchored, labelled[int]{label: block.Name, key: position})
		}
		effective[i] = running
	}
	if Sorted(anchored, func(a, b labelled[int]) int { return a.key - b.key }) {
		return nil, source, false, nil
	}
	if !fix {
		return []Finding{errorFinding("outputs", path,
			"outputs not ordered by main*.tf module/resource declaration order ("+
				firstRegression(anchored, "pos", compareInts, formatPosition)+")")}, source, false, nil
	}
	index := map[int]int{}
	for i, block := range blocks {
		index[block.Start] = i
	}
	rewritten, ok := Reorder(source, blocks[0].Start, blocks[len(blocks)-1].End, blocks, func(a, b Block) int {
		ia, ib := index[a.Start], index[b.Start]
		if effective[ia] != effective[ib] {
			return effective[ia] - effective[ib]
		}
		return ia - ib
	})
	if !ok {
		return []Finding{errorFinding("outputs", path,
			"outputs out of main.tf order; could not be safely auto-fixed")}, source, false, nil
	}
	return nil, rewritten, true, nil
}
