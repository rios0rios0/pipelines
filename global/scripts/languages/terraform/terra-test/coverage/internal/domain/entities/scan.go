package entities

import (
	"regexp"
	"slices"
	"sort"
	"strings"

	"github.com/rios0rios0/pipelines/global/scripts/languages/terraform/internal/text"
)

// RootNamespace is the namespace of a file declared directly in the module
// root, and the one a `tests/*.tftest.hcl` resolves against: `terraform test`
// evaluates a test against the module root, not against `tests/`.
const RootNamespace = "."

// localPrefix is the address prefix of a local value.
const localPrefix = "local."

// expectFailuresSeparator splits an `expect_failures` list into its entries.
var expectFailuresSeparator = regexp.MustCompile(`[,\n]`)

// denominatorKinds are the blocks that BEHAVE at apply time, so "was it
// exercised?" is a real question. `variable`, `locals`, `terraform`,
// `provider`, `moved`, `import` and `removed` declare; they do not behave.
func denominatorKinds() map[string]bool {
	return map[string]bool{"resource": true, kindData: true, kindModule: true, kindOutput: true, kindCheck: true}
}

// The block kinds the scan treats specially.
const (
	kindData   = "data"
	kindModule = "module"
	kindOutput = "output"
	kindCheck  = "check"
)

// expanding are the prefixes of the nodes that merely forward a reference.
// Only these expand in the closure: a resource, data, module or check
// address is terminal, so the closure never walks a whole dependency chain
// and calls it coverage.
func expanding() []string {
	return []string{localPrefix, "output.", "var."}
}

// Declared is one block in the denominator: the file, relative to the
// repository, the 1-based line of its keyword, and its qualified address.
type Declared struct {
	Path    string
	Line    int
	Address string
}

// ModuleScan is what one module declares, which address references which,
// and which addresses executed assertions name.
type ModuleScan struct {
	Declared []Declared
	Graph    map[string]map[string]bool
	Seeds    map[string]bool
}

// NewModuleScan starts an empty scan.
func NewModuleScan() *ModuleScan {
	return &ModuleScan{Graph: map[string]map[string]bool{}, Seeds: map[string]bool{}}
}

// Qualify scopes an address to the directory that declared it. An address is
// only unique within one directory: two nested submodules may each declare
// `aws_s3_bucket.this`, and while addresses were global to the whole module
// scan they shared one coverage entry, so an assertion on one marked the
// other covered. `@` cannot appear in an identifier, and the address stays in
// front, so a qualified node still starts with its prefix.
func Qualify(address, namespace string) string {
	return address + "@" + namespace
}

func qualifyAll(addresses map[string]bool, namespace string) map[string]bool {
	qualified := make(map[string]bool, len(addresses))
	for address := range addresses {
		qualified[Qualify(address, namespace)] = true
	}
	return qualified
}

func (s *ModuleScan) addEdge(node string, targets map[string]bool) {
	if len(targets) == 0 {
		return
	}
	if s.Graph[node] == nil {
		s.Graph[node] = map[string]bool{}
	}
	for target := range targets {
		s.Graph[node][target] = true
	}
}

func (s *ModuleScan) seed(addresses map[string]bool) {
	for address := range addresses {
		s.Seeds[address] = true
	}
}

// blockAddress is the address a block declares, if it declares one.
func blockAddress(block Block) (string, bool) {
	switch {
	case block.Kind == "resource" && len(block.Labels) >= 2:
		return block.Labels[0] + "." + block.Labels[1], true
	case block.Kind == kindData && len(block.Labels) >= 2:
		return kindData + "." + block.Labels[0] + "." + block.Labels[1], true
	case slices.Contains([]string{kindModule, kindOutput, kindCheck}, block.Kind) && len(block.Labels) > 0:
		return block.Kind + "." + block.Labels[0], true
	default:
		return "", false
	}
}

// conditionReferences are the addresses the `condition` of a guard names,
// qualified. `assert`, `precondition` and `postcondition` are three spellings
// of one thing: a boolean the test run really evaluates.
func conditionReferences(scanner Scanner, block Block, namespace string) map[string]bool {
	condition, _ := scanner.Expression(block.Open+1, block.Close, "condition")
	return qualifyAll(Traversals(condition), namespace)
}

// LineStarts are the offsets every line of `source` starts at.
func LineStarts(source string) []int {
	starts := []int{0}
	for at, character := range []byte(source) {
		if character == '\n' {
			starts = append(starts, at+1)
		}
	}
	return starts
}

// lineOf is the 1-based line `offset` falls on.
func lineOf(starts []int, offset int) int {
	return sort.Search(len(starts), func(i int) bool { return starts[i] > offset })
}

// ScanDeclarations records every block one file declares, and the edges out
// of it. `path` is the file relative to the repository and `namespace` its
// directory relative to the module; `hasTests` is whether the module has a
// test file that runs, without which no guard in it is ever evaluated.
func (s *ModuleScan) ScanDeclarations(source, path, namespace string, hasTests bool) {
	scanner := NewScanner(source, Mask(source))
	starts := LineStarts(source)
	for _, block := range scanner.Blocks(0, len(scanner.masked)) {
		if s.forwards(scanner, block, namespace) {
			continue
		}
		address, ok := blockAddress(block)
		if !ok || !denominatorKinds()[block.Kind] {
			continue
		}
		qualified := Qualify(address, namespace)
		s.Declared = append(s.Declared, Declared{Path: path, Line: lineOf(starts, block.Start), Address: qualified})
		if block.Kind == kindOutput {
			value, _ := scanner.Expression(block.Open+1, block.Close, "value")
			s.addEdge(qualified, qualifyAll(Traversals(value), namespace))
		}
		if hasTests {
			s.seedFromGuards(scanner, block, qualified, namespace)
		}
	}
}

// forwards records the edges of a block that only forwards references -- a
// `locals` block, each value an edge, or a `variable`, an edge to what its
// validations name -- and says whether the block was one.
func (s *ModuleScan) forwards(scanner Scanner, block Block, namespace string) bool {
	low, high := block.Open+1, block.Close
	switch {
	case block.Kind == "locals":
		for _, attribute := range scanner.Attributes(low, high) {
			s.addEdge(Qualify(localPrefix+attribute.Name, namespace),
				qualifyAll(Traversals(scanner.masked[attribute.Start:attribute.End]), namespace))
		}
		return true
	case block.Kind == "variable" && len(block.Labels) > 0:
		references := map[string]bool{}
		for _, nested := range scanner.BlocksDeep(low, high) {
			if nested.Kind == "validation" {
				addAll(references, conditionReferences(scanner, nested, namespace))
			}
		}
		s.addEdge(Qualify("var."+block.Labels[0], namespace), references)
		return true
	default:
		return false
	}
}

// addAll adds every key of `from` to `into`.
func addAll(into, from map[string]bool) {
	for key := range from {
		into[key] = true
	}
}

// seedFromGuards seeds a declared block from the guards `terraform test`
// really evaluates: a `check` is exercised, and so is everything its asserts
// name; a `lifecycle { pre|postcondition }` runs as part of its block, so the
// block is exercised, and so is everything its condition names.
func (s *ModuleScan) seedFromGuards(scanner Scanner, block Block, qualified, namespace string) {
	guards := []string{"precondition", "postcondition"}
	if block.Kind == kindCheck {
		s.Seeds[qualified] = true
		guards = append(guards, "assert")
	}
	for _, nested := range scanner.BlocksDeep(block.Open+1, block.Close) {
		if slices.Contains(guards, nested.Kind) {
			s.Seeds[qualified] = true
			s.seed(conditionReferences(scanner, nested, namespace))
		}
	}
}

// ScanTestFile adds the seeds one `*.tftest.hcl` contributes: what every
// `assert` condition names, and every `expect_failures` entry as written --
// `expect_failures` is how a test asserts a guard fires.
func (s *ModuleScan) ScanTestFile(source string) {
	scanner := NewScanner(source, Mask(source))
	for _, block := range scanner.BlocksDeep(0, len(scanner.masked)) {
		if block.Kind == "assert" {
			s.seed(conditionReferences(scanner, block, RootNamespace))
		}
	}
	for _, attribute := range scanner.AttributesDeep(0, len(scanner.masked)) {
		if attribute.Name != "expect_failures" {
			continue
		}
		list := text.StripChars(text.Strip(scanner.masked[attribute.Start:attribute.End]), "[]")
		for _, entry := range expectFailuresSeparator.Split(list, -1) {
			if entry = text.StripChars(text.Strip(entry), "[],"); entry != "" {
				s.Seeds[Qualify(entry, RootNamespace)] = true
			}
		}
	}
}

// Reachable is the transitive closure of the seeds over the graph, cycle
// safe; only forwarding nodes expand.
func (s *ModuleScan) Reachable() map[string]bool {
	seen := map[string]bool{}
	pending := make([]string, 0, len(s.Seeds))
	for seed := range s.Seeds {
		pending = append(pending, seed)
	}
	for len(pending) > 0 {
		node := pending[len(pending)-1]
		pending = pending[:len(pending)-1]
		if seen[node] {
			continue
		}
		seen[node] = true
		if slices.ContainsFunc(expanding(), func(prefix string) bool { return strings.HasPrefix(node, prefix) }) {
			for target := range s.Graph[node] {
				pending = append(pending, target)
			}
		}
	}
	return seen
}
