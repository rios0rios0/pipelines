package entities

import (
	"fmt"
	"regexp"
	"strconv"
)

var (
	hclMarker = regexp.MustCompile(`(?im)^[ \t]*(?://|#)[ \t]*SET ON \.HCL`)
	envMarker = regexp.MustCompile(`(?im)^[ \t]*(?://|#)[ \t]*SET ON \.ENV`)
)

// labelled is one item of a sequence a finding can point into: a name and
// the key it is ordered by.
type labelled[T any] struct {
	label string
	key   T
}

// firstRegression names the first item whose key is lower than the one
// before it: `'kube'(dep 01) after dep 03 ('registry')`.
func firstRegression[T any](
	sequence []labelled[T],
	unit string,
	compare func(a, b T) int,
	format func(T) string,
) string {
	for i := 1; i < len(sequence); i++ {
		if compare(sequence[i].key, sequence[i-1].key) < 0 {
			return fmt.Sprintf("'%s'(%s %s) after %s %s ('%s')", sequence[i].label, unit,
				format(sequence[i].key), unit, format(sequence[i-1].key), sequence[i-1].label)
		}
	}
	return "out of order"
}

// CheckVariables holds a stack's `variables.tf` to rule C: a `// SET ON .HCL`
// section before a `// SET ON .ENV` one, and inside `.HCL` the variables fed
// by a numbered dependency ordered by that number. `tags`, literals and
// defaulted flags are fed by no dependency and may sit anywhere -- "variables
// from dependency 03 before variables from dependency 04", nothing more. With
// `fix` it returns the rewritten text and true when it rewrote it.
func CheckVariables(source, path string, inputs map[string]Number, fix bool) ([]Finding, string, bool, error) {
	hcl, env := hclMarker.FindStringIndex(source), envMarker.FindStringIndex(source)
	if hcl == nil && env == nil {
		return []Finding{warningFinding("variables-markers", path,
			"missing `// SET ON .HCL` / `// SET ON .ENV` section markers")}, source, false, nil
	}
	if hcl != nil && env != nil && env[0] < hcl[0] {
		return []Finding{errorFinding("variables-sections", path,
			"`// SET ON .ENV` section appears before `// SET ON .HCL`")}, source, false, nil
	}
	start, end := 0, len(source)
	if hcl != nil {
		start = hcl[1]
	}
	if env != nil {
		end = env[0]
	}
	blocks, err := TopLevelBlocks(source, "variable")
	if err != nil {
		return nil, "", false, err
	}
	var section []Block
	var mapped []labelled[Number]
	for _, block := range blocks {
		if block.Start < start || block.Start >= end {
			continue
		}
		section = append(section, block)
		if number, fed := inputs[block.Name]; fed {
			mapped = append(mapped, labelled[Number]{label: block.Name, key: number})
		}
	}
	if Sorted(mapped, func(a, b labelled[Number]) int { return a.key.Compare(b.key) }) {
		return nil, source, false, nil
	}
	if !fix {
		return []Finding{errorFinding("variables-order", path, "`.HCL` variables not ordered by dependency number ("+
			firstRegression(mapped, "dep", compareNumbers, Number.String)+")")}, source, false, nil
	}
	rewritten, ok := ReorderPinned(source, section[0].Start, section[len(section)-1].End, blocks,
		func(block Block) bool { _, fed := inputs[block.Name]; return fed },
		func(a, b Block) int { return numberOr(inputs, a.Name).Compare(numberOr(inputs, b.Name)) })
	if !ok {
		return []Finding{errorFinding("variables-order", path,
			".HCL variables out of dependency-number order; could not be safely auto-fixed")}, source, false, nil
	}
	return nil, rewritten, true, nil
}

// numberOr is a variable's dependency number, unmapped when it has none.
func numberOr(inputs map[string]Number, name string) Number {
	if number, found := inputs[name]; found {
		return number
	}
	return Unmapped()
}

// formatPosition renders a declaration position at two digits or more.
func formatPosition(position int) string {
	if position >= 0 && position < 10 {
		return "0" + strconv.Itoa(position)
	}
	return strconv.Itoa(position)
}
