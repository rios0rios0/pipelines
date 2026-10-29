package entities

import (
	"regexp"
	"slices"
	"strings"

	"github.com/rios0rios0/pipelines/global/scripts/languages/terraform/internal/text"
)

var (
	environmentNumber = regexp.MustCompile(`environments/(\p{Nd}+)_`)
	sourceStack       = regexp.MustCompile(`source` + text.Space + `*=` + text.Space + `*"[^"]*stacks/([^"/]+)"`)
	dependencyRef     = regexp.MustCompile(`dependency\.([A-Za-z0-9_]+)\.outputs`)
)

// Dependency is a `dependency` block and the layer number its `config_path`
// names.
type Dependency struct {
	Name   string
	Number Number
}

// RootHcl is what the ordering rules read out of an `environments/**/root.hcl`.
type RootHcl struct {
	// Numbers maps each dependency to its layer number.
	Numbers map[string]Number
	// Dependencies are the dependency blocks in file order.
	Dependencies []Dependency
	// Stack is the single stack name its `source` names, empty when none.
	Stack string
	// Inputs maps each input fed by a dependency to that dependency's number.
	Inputs map[string]Number
	// References are the dependencies the inputs read, in file order.
	References []Dependency
}

// ParseRootHcl reads a root.hcl's dependencies, the stack it feeds, and which
// dependency feeds each input.
func ParseRootHcl(source string) (RootHcl, error) {
	blocks, err := TopLevelBlocks(source, "dependency")
	if err != nil {
		return RootHcl{}, err
	}
	root := RootHcl{Numbers: map[string]Number{}, Inputs: map[string]Number{}}
	for _, block := range blocks {
		number := Unmapped()
		if match := environmentNumber.FindStringSubmatch(source[block.Start:block.End]); match != nil {
			number = ParseNumber(match[1])
		}
		root.Numbers[block.Name] = number
		root.Dependencies = append(root.Dependencies, Dependency{Name: block.Name, Number: number})
	}
	if match := sourceStack.FindStringSubmatch(source); match != nil {
		root.Stack = match[1]
	}
	body, found, err := InputsBody(source)
	if err != nil || !found {
		return root, err
	}
	// The same balanced parser the fixer uses, so a dependency reference on a
	// later line of a multi-line value counts for the check too.
	entries, _ := SplitEntries(body)
	for _, entry := range entries {
		if reference := dependencyRef.FindStringSubmatch(entry.Value); reference != nil {
			number := root.number(reference[1])
			root.Inputs[entry.Key] = number
			root.References = append(root.References, Dependency{Name: reference[1], Number: number})
		}
	}
	return root, nil
}

// number is a dependency's layer number, unmapped when it is not declared.
func (r RootHcl) number(name string) Number {
	if number, found := r.Numbers[name]; found {
		return number
	}
	return Unmapped()
}

// listed renders dependencies the way a finding lists them: `name(03), ...`.
func listed(dependencies []Dependency) string {
	parts := make([]string, len(dependencies))
	for i, dependency := range dependencies {
		parts[i] = dependency.Name + "(" + dependency.Number.String() + ")"
	}
	return strings.Join(parts, ", ")
}

func numbersOf(dependencies []Dependency) []Number {
	numbers := make([]Number, len(dependencies))
	for i, dependency := range dependencies {
		numbers[i] = dependency.Number
	}
	return numbers
}

func compareNumbers(a, b Number) int {
	return a.Compare(b)
}

// CheckRootHcl holds a root.hcl to rules A -- dependency blocks ascending by
// layer number -- and B -- inputs grouped by ascending dependency number,
// locals and tags first and literals last. With `fix` it returns the
// rewritten text and true when it changed anything; a region it cannot
// rewrite safely is reported instead.
func CheckRootHcl(root RootHcl, source, path string, fix bool) ([]Finding, string, bool, error) {
	findings, source, changedDependencies, err := checkDependencies(root, source, path, fix)
	if err != nil {
		return nil, "", false, err
	}
	inputFindings, source, changedInputs, err := checkInputs(root, source, path, fix)
	if err != nil {
		return nil, "", false, err
	}
	return append(findings, inputFindings...), source, changedDependencies || changedInputs, nil
}

// checkDependencies is rule A.
func checkDependencies(root RootHcl, source, path string, fix bool) ([]Finding, string, bool, error) {
	if Sorted(numbersOf(root.Dependencies), compareNumbers) {
		return nil, source, false, nil
	}
	if !fix {
		return []Finding{
			errorFinding(
				"root-hcl-deps",
				path,
				"dependency blocks not ascending by environments/NN number: "+listed(
					root.Dependencies,
				),
			),
		}, source, false, nil
	}
	blocks, err := TopLevelBlocks(source, "dependency")
	if err != nil {
		return nil, "", false, err
	}
	rewritten, ok := Reorder(source, blocks[0].Start, blocks[len(blocks)-1].End, blocks,
		func(a, b Block) int { return root.number(a.Name).Compare(root.number(b.Name)) })
	if !ok {
		return []Finding{errorFinding("root-hcl-deps", path,
			"dependency blocks out of order and could not be safely auto-fixed")}, source, false, nil
	}
	return nil, rewritten, true, nil
}

// checkInputs is rule B.
func checkInputs(root RootHcl, source, path string, fix bool) ([]Finding, string, bool, error) {
	if Sorted(numbersOf(root.References), compareNumbers) {
		return nil, source, false, nil
	}
	if !fix {
		return []Finding{errorFinding("root-hcl-inputs", path,
			"inputs not grouped by ascending dependency number: "+listed(root.References))}, source, false, nil
	}
	rewritten, fixed, ok, err := fixInputs(source, root)
	switch {
	case err != nil:
		return nil, "", false, err
	case fixed:
		return nil, rewritten, true, nil
	case !ok:
		return []Finding{errorFinding("root-hcl-inputs", path,
			"inputs block out of order and could not be safely auto-fixed")}, source, false, nil
	default:
		return nil, source, false, nil
	}
}

// fixInputs reorders the dependency-fed assignments of the `inputs` block by
// dependency number, stably, back into the positions they held, so leading
// locals and tags and trailing literals stay where they are. It returns the
// new text, whether it changed, and whether the block round-tripped.
func fixInputs(source string, root RootHcl) (string, bool, bool, error) {
	location := inputsBlock.FindStringIndex(source)
	if location == nil {
		return source, false, true, nil
	}
	open := location[0] + strings.IndexByte(source[location[0]:], '{')
	closing, err := MatchingBrace(source, open)
	if err != nil {
		return "", false, false, err
	}
	body := source[open+1 : closing]
	entries, suffix := SplitEntries(body)
	if joinEntries(entries)+suffix != body {
		return source, false, false, nil
	}
	var slots []int
	var fed []Entry
	numbers := map[int]Number{}
	for index, entry := range entries {
		if reference := dependencyRef.FindStringSubmatch(entry.Value); reference != nil {
			numbers[len(fed)] = root.number(reference[1])
			slots = append(slots, index)
			fed = append(fed, entry)
		}
	}
	order := make([]int, len(fed))
	for i := range order {
		order[i] = i
	}
	slices.SortStableFunc(order, func(a, b int) int { return numbers[a].Compare(numbers[b]) })
	reordered := slices.Clone(entries)
	for i, slot := range slots {
		reordered[slot] = fed[order[i]]
	}
	newBody := joinEntries(reordered) + suffix
	if newBody == body {
		return source, false, true, nil
	}
	return source[:open+1] + newBody + source[closing:], true, true, nil
}

func joinEntries(entries []Entry) string {
	var b strings.Builder
	for _, entry := range entries {
		b.WriteString(entry.Text)
	}
	return b.String()
}
