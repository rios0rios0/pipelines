package main

import (
	"fmt"
	"io"
	"path/filepath"
	"regexp"
	"sort"
	"strings"

	"github.com/rios0rios0/pipelines/internal/testsuites/filetext"
	"github.com/rios0rios0/pipelines/internal/testsuites/yamldoc"
)

// The assertions a finding is reported under.
const (
	groupParse      = "parse"
	groupUnmapped   = "unmapped"
	groupClassified = "classified"
	groupMacro      = "macro"
)

// thisSuite is where the classification tables live, as the suite names it.
const thisSuite = ".github/tests/test-azure-secret-env.sh"

var (
	// shellRead is a variable a shell body reads: `$NAME` or `${NAME`.
	shellRead = regexp.MustCompile(`\$\{?([A-Z][A-Z0-9_]*)\b`)
	// macroUse is an Azure macro, which the agent expands everywhere in a script.
	macroUse = regexp.MustCompile(`\$\(([A-Za-z_][A-Za-z0-9_.]*)\)`)
	// upperWord is any upper-case identifier a file mentions.
	upperWord = regexp.MustCompile(`\b[A-Z][A-Z0-9_]*\b`)
)

// Azure's four shell-step shortcuts are one class: each carries a script body that
// the agent macro-expands identically. Matching only `script:` made the other three
// invisible to assertions 2 and 4 -- and `bash:` is the idiomatic form in this
// repository (including every `eval "$PIPELINES_HOOK"` deployment hook), so those
// steps passed by never being looked at. Do not narrow this back.
func shellKeys() []string {
	return []string{"script", "bash", "pwsh", "powershell"}
}

type finding struct {
	group string
	line  string
}

// checker accumulates what one run of the check finds.
type checker struct {
	root           string
	contract       contract
	scriptReads    map[string]map[string]bool
	steps          []step
	findings       []finding
	mentioned      map[string]bool
	mappedAnywhere map[string]bool
}

// check runs every assertion over the repository at `root` and writes one
// `<group>\t<finding>` line per violation.
func check(root string, output io.Writer) error {
	c := &checker{
		root:           root,
		contract:       secretContract(),
		scriptReads:    map[string]map[string]bool{},
		mentioned:      map[string]bool{},
		mappedAnywhere: map[string]bool{},
	}
	stages := []func() error{c.readScripts, c.readTemplates, c.checkSteps, c.checkMentions}
	for _, stage := range stages {
		if err := stage(); err != nil {
			return err
		}
	}
	for _, found := range c.findings {
		if _, err := fmt.Fprintf(output, "%s\t%s\n", found.group, found.line); err != nil {
			return err
		}
	}
	return nil
}

func (c *checker) report(group, file, detail string) {
	c.findings = append(c.findings, finding{group: group, line: file + ": " + detail})
}

func (c *checker) relative(path string) string {
	relative, err := filepath.Rel(c.root, path)
	if err != nil {
		return path
	}
	return relative
}

// credentialsIn are the credential-shaped variables a shell body reads.
func (c *checker) credentialsIn(text string) map[string]bool {
	found := map[string]bool{}
	for _, match := range shellRead.FindAllStringSubmatch(text, -1) {
		if c.contract.isCredential(match[1]) {
			found[match[1]] = true
		}
	}
	return found
}

// readScripts records what each of this repository's own scripts reads.
func (c *checker) readScripts() error {
	return filetext.Walk(filepath.Join(c.root, "global", "scripts"), nil, func(path string) error {
		if !strings.HasSuffix(path, ".sh") {
			return nil
		}
		text, err := filetext.Read(path)
		if err != nil {
			return err
		}
		if names := c.credentialsIn(filetext.StripComments(text)); len(names) > 0 {
			c.scriptReads[c.relative(path)] = names
		}
		return nil
	})
}

// readTemplates collects every step of every Azure template. A template that
// does not parse expands to no steps, so every assertion would pass for the
// worst possible reason: it is reported instead.
func (c *checker) readTemplates() error {
	return filetext.Walk(filepath.Join(c.root, "azure-devops"), nil, func(path string) error {
		if !strings.HasSuffix(path, ".yaml") && !strings.HasSuffix(path, ".yml") {
			return nil
		}
		document, err := yamldoc.Load(path, yamldoc.Options{})
		if err != nil {
			c.report(groupParse, c.relative(path), strings.Join(strings.Fields(err.Error()), " "))
			return nil
		}
		collectSteps(document, c.relative(path), &c.steps)
		return nil
	})
}

// checkSteps holds assertions 2 and 4 and the declared half of 3.
func (c *checker) checkSteps() error {
	for _, found := range c.steps {
		c.checkMapping(found)
	}
	for _, found := range c.steps {
		c.checkMacros(found)
	}
	known := map[stepKey]bool{}
	for _, found := range c.steps {
		if key, ok := found.key(); ok {
			known[key] = true
		}
	}
	for _, entry := range c.contract.declared {
		if !known[entry.step] {
			c.report(groupClassified, entry.step.file, fmt.Sprintf(
				"no step named %s -- the declared table names a step that no longer exists, "+
					"so its credential is unchecked", yamldoc.Quote(entry.step.displayName)))
		}
	}
	return nil
}

// checkMapping holds assertion 2 for one step: every credential it consumes
// arrives through `env:`.
func (c *checker) checkMapping(found step) {
	mapped := found.mappedNames()
	for name := range mapped {
		if c.contract.isCredential(name) {
			c.mappedAnywhere[name] = true
			c.mentioned[name] = true
		}
	}
	allowed := map[string]bool{}
	if key, named := found.key(); named {
		for _, name := range c.contract.exemptSteps[key] {
			allowed[name] = true
		}
	}
	for _, name := range sortedNames(c.consumed(found)) {
		c.mentioned[name] = true
		if mapped[name] || allowed[name] {
			continue
		}
		if _, exempt := c.contract.exempt[name]; exempt {
			continue
		}
		c.report(groupUnmapped, found.file, fmt.Sprintf(
			"step %s reads %s but never maps it through `env:`", found.label(), name))
	}
}

// consumed are the credentials a step consumes, established two ways, because
// the defect hides in two places:
//
//  1. DERIVED: what a script of this repository the step runs reads, plus what
//     the step's own body reads. Mechanical, with no list to maintain.
//  2. DECLARED: what a third-party tool reads STRAIGHT FROM THE ENVIRONMENT. It
//     has no textual reference to the variable anywhere -- `safety` is the
//     archetype -- so it cannot be derived and is declared instead.
func (c *checker) consumed(found step) map[string]bool {
	needed := c.credentialsIn(filetext.StripComments(found.scriptText()))
	texts := found.otherStrings()
	for _, text := range texts {
		for name := range c.credentialsIn(text) {
			needed[name] = true
		}
	}
	for script, names := range c.scriptReads {
		if found.mentions(script, texts) {
			for name := range names {
				needed[name] = true
			}
		}
	}
	if key, named := found.key(); named {
		for _, name := range c.contract.declaredFor(key) {
			needed[name] = true
		}
	}
	return needed
}

// checkMacros holds assertion 4 for one step. Azure expands `$(NAME)` everywhere
// in a step's script, comments included, and writes the result to a file on the
// agent, so naming a credential that way puts its VALUE in the script text.
func (c *checker) checkMacros(found step) {
	if !found.script.IsString() {
		return
	}
	for _, match := range macroUse.FindAllStringSubmatch(found.script.Text(), -1) {
		if c.contract.isCredential(match[1]) {
			c.report(groupMacro, found.file, fmt.Sprintf(
				"step %s spells %s inside its script, so Azure substitutes the credential's VALUE into "+
					"the script text -- pass it through `env:` and read it as a shell variable instead",
				found.label(), match[0]))
		}
	}
}

// checkMentions holds the other half of assertion 3: every credential-shaped
// variable the Azure templates and their scripts mention is classified. It is
// scoped there because that is where the defect lives: GitLab injects masked
// variables and GitHub never makes a secret ambient.
func (c *checker) checkMentions() error {
	for _, base := range []string{"azure-devops", filepath.Join("global", "scripts")} {
		err := filetext.Walk(filepath.Join(c.root, base), nil, func(path string) error {
			if !hasAnySuffix(path, ".yaml", ".yml", ".sh") {
				return nil
			}
			text, err := filetext.Read(path)
			if err != nil {
				return err
			}
			for _, name := range upperWord.FindAllString(filetext.StripComments(text), -1) {
				if c.contract.isCredential(name) {
					c.mentioned[name] = true
				}
			}
			return nil
		})
		if err != nil {
			return err
		}
	}
	declared := c.contract.declaredNames()
	for _, name := range sortedNames(c.mentioned) {
		if _, exempt := c.contract.exempt[name]; c.mappedAnywhere[name] || declared[name] || exempt {
			continue
		}
		c.report(groupClassified, thisSuite, name+" is credential-shaped but no Azure step maps it, and it is "+
			"neither declared nor exempt -- classify it so it cannot be passed ambiently by accident")
	}
	return nil
}

func hasAnySuffix(path string, suffixes ...string) bool {
	for _, suffix := range suffixes {
		if strings.HasSuffix(path, suffix) {
			return true
		}
	}
	return false
}

func sortedNames(names map[string]bool) []string {
	sorted := make([]string, 0, len(names))
	for name := range names {
		sorted = append(sorted, name)
	}
	sort.Strings(sorted)
	return sorted
}
