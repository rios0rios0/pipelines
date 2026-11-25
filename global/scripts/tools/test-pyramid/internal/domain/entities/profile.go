package entities

import (
	"fmt"
	"regexp"
	"strings"
)

// Dialect is how a profile counts the test cases of a file.
type Dialect int

const (
	// DialectLine counts each line that matches the profile's Cases as one test case.
	DialectLine Dialect = iota
	// DialectMarker counts one test case per method that a marker line (an attribute or an
	// annotation: `[Fact]`, `#[Test]`, `@test`) precedes, however many markers it carries, and
	// each line that is a test case on its own (a PHPUnit `function test...`).
	DialectMarker
	// DialectTerraform counts each `run` block as one test case with a tier of its own, and each
	// Go test of a Terratest file.
	DialectTerraform
)

// Profile is one language's classification rules: data, which Classify reads and never extends.
//
// A test file is in ONE tier, decided by the first of these that says anything, and only by it:
//
//  1. the repository's path rules (`.test-pyramid`), first match, which may also lower a tier
//  2. evidence in the file: the highest tier any of its lines DECLARES -- a build tag, a test
//     category, a marker the test runner selects on -- or CROSSES, a signature of the boundary
//     the test exercises: a browser driver, an in-process HTTP client of the application, a
//     container
//  3. the path: the highest tier the language's naming conventions, and those every language
//     shares, give it
//  4. unit
//
// A signature is chosen for precision over recall: one that fires on a unit test moves it up the
// pyramid and blames a pull request for a shape it did not make. It names a driver or a client
// whose only use is the boundary it stands for; a test double never raises a tier.
type Profile struct {
	Language string
	// Files are the paths whose test cases count; Exclude the paths never read.
	Files   *regexp.Regexp
	Exclude *regexp.Regexp
	Dialect Dialect
	// Cases is a test-case line, for DialectLine; Skip a line that matched Cases and is not one.
	Cases *regexp.Regexp
	Skip  *regexp.Regexp
	// Marker, Declaration and Self are DialectMarker's marker line, method declaration and
	// self-contained test-case line.
	Marker      *regexp.Regexp
	Declaration *regexp.Regexp
	Self        *regexp.Regexp
	// Run, Plan and Mock are DialectTerraform's `run` block, plan-only command and mocked
	// provider; GoTest a Terratest test.
	Run    *regexp.Regexp
	Plan   *regexp.Regexp
	Mock   *regexp.Regexp
	GoTest *regexp.Regexp
	// Evidence is, for each tier above unit, a line that puts the whole file in it (nil for none).
	Evidence [tierCount]*regexp.Regexp
	// Paths is, for each tier above unit, this language's naming convention for it (nil for none).
	Paths [tierCount]*regexp.Regexp
	// Conventions are the naming conventions every language shares, nil for a language whose own
	// declaration decides the tier and whose paths may not contradict it (Go's build tags).
	Conventions []PathConvention
}

// PathConvention is how every language names a tier in a path: a directory segment that is the
// tier's word, alone or joined to others by `.`, `_` or `-` (`integration/`, `e2e-tests/`,
// `MyApp.IntegrationTests/`) but never inside another word (`integrations/` and `ui/` name
// nothing), a token of the file name (`user_integration_test.go`, `login.e2e.ts`), or a CamelCase
// suffix (`UserIntegrationTest.java`, `UserIT.java`, `CheckoutE2ETest.cs`).
type PathConvention struct {
	Tier      Tier
	Directory *regexp.Regexp
	Token     *regexp.Regexp
	Camel     *regexp.Regexp
}

// PathRule is a rule of the repository's `.test-pyramid`: a test file whose path matches Pattern
// is in Tier, or left out of the pyramid for TierIgnored.
type PathRule struct {
	Tier    Tier
	Pattern *regexp.Regexp
}

// TestFile is a file of a tree that a profile reads, with its content.
type TestFile struct {
	Path    string
	Content string
}

// FileTier is how a file's test cases count: their tier, how many, and the rule that decided --
// `rule <n>`, `evidence`, `path` or `default`, and for a Terraform file `mocked`, `plan` or `apply`.
type FileTier struct {
	Path   string
	Tier   Tier
	Cases  int
	Reason string
}

// Classification is one tree's suite: every test file's tier, and the test cases of each tier.
type Classification struct {
	Files  []FileTier
	Counts Counts
}

// Reads is whether the profile counts the test cases of a file at this path.
func (p Profile) Reads(path string) bool {
	return p.Files.MatchString(path) && (p.Exclude == nil || !p.Exclude.MatchString(path))
}

// Classify puts every test case of the files in a tier. The same files and rules always give the
// same classification, each file's decision recorded with its reason.
func (p Profile) Classify(files []TestFile, rules []PathRule) Classification {
	classification := Classification{Counts: Counts{}}
	for _, file := range files {
		if !p.Reads(file.Path) {
			continue
		}
		for _, part := range p.classify(file, rules) {
			classification.Files = append(classification.Files, part)
			classification.Counts[part.Tier] += part.Cases
		}
	}
	return classification
}

func (p Profile) classify(file TestFile, rules []PathRule) []FileTier {
	found := p.count(file)
	if found.cases == 0 {
		return nil
	}
	for index, rule := range rules {
		if rule.Pattern.MatchString(file.Path) {
			return []FileTier{
				{Path: file.Path, Tier: rule.Tier, Cases: found.cases, Reason: fmt.Sprintf("rule %d", index+1)},
			}
		}
	}
	tier, reason := found.evidence, "evidence"
	if tier == TierIgnored {
		tier, reason = p.pathTier(file.Path), "path"
		if tier == TierUnit {
			reason = "default"
		}
	}
	if found.runs > 0 && tier == TierUnit {
		// A Terraform test file: each run keeps the tier its own command gives it.
		return nonEmpty([]FileTier{
			{Path: file.Path, Tier: TierUnit, Cases: found.runs - found.applies, Reason: found.unitReason()},
			{Path: file.Path, Tier: TierIntegration, Cases: found.applies, Reason: "apply"},
		})
	}
	return []FileTier{{Path: file.Path, Tier: tier, Cases: found.cases, Reason: reason}}
}

// pathTier is the highest tier the language's conventions, then the shared ones, give a path.
func (p Profile) pathTier(path string) Tier {
	lower := strings.ToLower(path)
	directory, name := splitPath(lower)
	_, camel := splitPath(path)
	for index := len(Tiers()) - 1; index > 0; index-- {
		tier := Tiers()[index]
		if pattern := p.Paths[tier]; pattern != nil && pattern.MatchString(path) {
			return tier
		}
		for _, convention := range p.Conventions {
			if convention.Tier == tier && (convention.Directory.MatchString(directory) ||
				convention.Token.MatchString(name) || convention.Camel.MatchString(camel)) {
				return tier
			}
		}
	}
	return TierUnit
}

// tally is what one file holds: its test cases, the highest tier its evidence names (TierIgnored
// for none) and, for a Terraform test file, its runs and how many of them apply.
type tally struct {
	cases    int
	evidence Tier
	runs     int
	applies  int
	mocked   bool
}

func (t tally) unitReason() string {
	if t.mocked {
		return "mocked"
	}
	return "plan"
}

func (p Profile) count(file TestFile) tally {
	found := tally{evidence: TierIgnored}
	pending, planned := false, false
	for line := range strings.Lines(file.Content) {
		line = strings.TrimRight(line, "\r\n")
		found.evidence = max(found.evidence, p.evidenceOf(line))
		switch p.Dialect {
		case DialectLine:
			if p.Cases.MatchString(line) && (p.Skip == nil || !p.Skip.MatchString(line)) {
				found.cases++
			}
		case DialectMarker:
			pending = p.marked(line, pending, &found)
		case DialectTerraform:
			planned = p.terraform(file.Path, line, planned, &found)
		}
	}
	if found.runs > 0 && !planned && !found.mocked {
		found.applies++
	}
	if found.mocked {
		found.applies = 0
	}
	return found
}

func (p Profile) evidenceOf(line string) Tier {
	for index := len(Tiers()) - 1; index > 0; index-- {
		tier := Tiers()[index]
		if pattern := p.Evidence[tier]; pattern != nil && pattern.MatchString(line) {
			return tier
		}
	}
	return TierIgnored
}

// marked counts DialectMarker's test cases and returns whether a marker still waits for its method.
func (p Profile) marked(line string, pending bool, found *tally) bool {
	declaration := p.Declaration != nil && p.Declaration.MatchString(line)
	self := p.Self != nil && p.Self.MatchString(line)
	if p.Marker.MatchString(line) {
		if declaration {
			found.cases++
			return false
		}
		return true
	}
	if declaration {
		if pending || self {
			found.cases++
		}
		return false
	}
	if self {
		found.cases++
	}
	return pending
}

// terraform counts DialectTerraform's test cases and returns whether the current run is plan-only.
// A run applies unless a `command = plan` follows it before the next run, or the file is mocked.
func (p Profile) terraform(path, line string, planned bool, found *tally) bool {
	if strings.HasSuffix(path, ".go") {
		if p.GoTest.MatchString(line) && (p.Skip == nil || !p.Skip.MatchString(line)) {
			found.cases++
		}
		return planned
	}
	switch {
	case p.Run.MatchString(line):
		if found.runs > 0 && !planned {
			found.applies++
		}
		found.runs++
		found.cases++
		return false
	case p.Plan.MatchString(line):
		return found.runs > 0
	case p.Mock.MatchString(line):
		found.mocked = true
	}
	return planned
}

// splitPath is a path's directory, with its trailing `/` (empty at the root), and its file name.
func splitPath(path string) (string, string) {
	slash := strings.LastIndex(path, "/")
	return path[:slash+1], path[slash+1:]
}

func nonEmpty(parts []FileTier) []FileTier {
	kept := parts[:0]
	for _, part := range parts {
		if part.Cases > 0 {
			kept = append(kept, part)
		}
	}
	return kept
}
