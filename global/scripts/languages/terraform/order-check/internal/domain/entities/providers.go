package entities

import (
	"regexp"
	"slices"
	"strings"

	"github.com/rios0rios0/pipelines/global/scripts/languages/terraform/internal/text"
)

var (
	requiredProviders = regexp.MustCompile(`required_providers` + text.Space + `*\{`)
	providerEntry     = regexp.MustCompile(`(?m)^[ \t]*([A-Za-z0-9_-]+)` + text.Space + `*=` + text.Space + `*\{`)
)

// unrankedWeight is the weight of a provider the ranking does not know: it
// never moves, so the value only has to sort after every ranked one.
const unrankedWeight = 9999

// weightOf is a provider's rank, unranked ones last.
func weightOf(weights map[string]int, name string) int {
	if weight, found := weights[name]; found {
		return weight
	}
	return unrankedWeight
}

// rankedWeights are the weights of the ranked names, in order.
func rankedWeights(weights map[string]int, names []string) []int {
	var ranked []int
	for _, name := range names {
		if weight, found := weights[name]; found {
			ranked = append(ranked, weight)
		}
	}
	return ranked
}

func compareInts(a, b int) int {
	return a - b
}

// CheckProviders holds a `providers.tf` to rule D: the `required_providers`
// entries and the top-level `provider` blocks ordered heaviest to lightest by
// the ranking. A provider the ranking does not know is a warning; the fixer
// leaves it where it is and sorts the rest around it. With `fix` it returns
// the rewritten text and true when it changed anything.
func CheckProviders(source, path string, weights map[string]int, fix bool) ([]Finding, string, bool, error) {
	findings, source, changed, err := checkRequiredProviders(source, path, weights, fix)
	if err != nil {
		return nil, "", false, err
	}
	blocks, err := TopLevelBlocks(source, "provider")
	if err != nil || len(blocks) == 0 {
		return findings, source, changed, err
	}
	names := make([]string, len(blocks))
	for i, block := range blocks {
		names[i] = block.Name
	}
	if Sorted(rankedWeights(weights, names), compareInts) {
		return findings, source, changed, nil
	}
	if !fix {
		return append(findings, errorFinding("providers", path,
			"provider blocks not ordered heaviest->lightest: "+text.ReprList(names))), source, changed, nil
	}
	rewritten, ok := ReorderPinned(source, blocks[0].Start, blocks[len(blocks)-1].End, blocks,
		func(block Block) bool { _, ranked := weights[block.Name]; return ranked },
		func(a, b Block) int { return weightOf(weights, a.Name) - weightOf(weights, b.Name) })
	switch {
	case !ok:
		findings = append(findings, errorFinding("providers", path,
			"provider blocks out of order; could not be safely auto-fixed"))
	case rewritten != source:
		source, changed = rewritten, true
	}
	return findings, source, changed, nil
}

// checkRequiredProviders is rule D for the `required_providers` entries.
func checkRequiredProviders(source, path string, weights map[string]int, fix bool) ([]Finding, string, bool, error) {
	location := requiredProviders.FindStringIndex(source)
	if location == nil {
		return nil, source, false, nil
	}
	open := location[0] + strings.IndexByte(source[location[0]:], '{')
	closing, err := MatchingBrace(source, open)
	if err != nil {
		return nil, "", false, err
	}
	inner := source[open+1 : closing]
	entries, err := providerEntries(inner)
	if err != nil {
		return nil, "", false, err
	}
	names := make([]string, len(entries))
	var unknown []string
	for i, entry := range entries {
		names[i] = entry.Name
		if _, ranked := weights[entry.Name]; !ranked && !slices.Contains(unknown, entry.Name) {
			unknown = append(unknown, entry.Name)
		}
	}
	var findings []Finding
	if len(unknown) > 0 {
		slices.Sort(unknown)
		findings = append(findings, warningFinding("providers", path,
			"providers not in the ranking (add to .terraform-order.json): "+strings.Join(unknown, ", ")))
	}
	if Sorted(rankedWeights(weights, names), compareInts) {
		return findings, source, false, nil
	}
	if !fix {
		return append(findings, errorFinding("providers", path,
			"required_providers not ordered heaviest->lightest: "+text.ReprList(names))), source, false, nil
	}
	rewritten, ok := reorderEntries(inner, entries, weights)
	switch {
	case !ok:
		return append(findings, errorFinding("providers", path,
			"required_providers out of order; could not be safely auto-fixed")), source, false, nil
	case rewritten != inner:
		return findings, source[:open+1] + rewritten + source[closing:], true, nil
	default:
		return findings, source, false, nil
	}
}

// providerEntries are the `name = { ... }` entries of a `required_providers`
// body, each as a block of that body.
func providerEntries(inner string) ([]Block, error) {
	var entries []Block
	for _, match := range providerEntry.FindAllStringSubmatchIndex(inner, -1) {
		open := match[0] + strings.IndexByte(inner[match[0]:], '{')
		closing, err := MatchingBrace(inner, open)
		if err != nil {
			return nil, err
		}
		end := closing + 1
		if end < len(inner) && inner[end] == '\n' {
			end++
		}
		entries = append(entries, Block{Name: inner[match[2]:match[3]], Start: match[0], End: end})
	}
	return entries, nil
}

// reorderEntries sorts the ranked entries among their own slots, the unranked
// ones pinned, and answers false when the body does not round-trip.
func reorderEntries(inner string, entries []Block, weights map[string]int) (string, bool) {
	prefix := inner[:entries[0].Start]
	var items []item
	cursor := entries[0].Start
	for _, entry := range entries {
		items = append(items, item{block: entry, text: slice(inner, cursor, entry.End)})
		cursor = entry.End
	}
	suffix := slice(inner, cursor, len(inner))
	if prefix+joinItems(items)+suffix != inner {
		return "", false
	}
	reordered := pinned(items,
		func(block Block) bool { _, ranked := weights[block.Name]; return ranked },
		func(a, b Block) int { return weightOf(weights, a.Name) - weightOf(weights, b.Name) })
	return prefix + joinItems(reordered) + suffix, true
}

func joinItems(items []item) string {
	var b strings.Builder
	for _, piece := range items {
		b.WriteString(piece.text)
	}
	return b.String()
}
