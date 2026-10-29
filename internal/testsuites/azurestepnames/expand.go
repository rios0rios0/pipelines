package main

import (
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"slices"
	"sort"
	"strings"

	"github.com/rios0rios0/pipelines/internal/testsuites/filetext"
	"github.com/rios0rios0/pipelines/internal/testsuites/yamldoc"
)

// scriptsDirectory is the variable `scripts-repo.yaml` sets for the job.
const scriptsDirectory = "$(Scripts.Directory)"

// problem is a template the expansion could not read.
type problem struct {
	file   string
	detail string
}

// job is one expanded job and what the assertions need to know about it.
type job struct {
	file           string
	name           *yamldoc.Node
	duplicates     map[string]int
	hasScriptsRepo bool
	usesScripts    bool
}

// key identifies a job's findings, so a job reachable from more than one entry
// template is reported once.
func (j job) key() string {
	names := make([]string, 0, len(j.duplicates))
	for name, count := range j.duplicates {
		names = append(names, fmt.Sprintf("%s=%d", yamldoc.Quote(name), count))
	}
	sort.Strings(names)
	return fmt.Sprintf("%s\x00%s\x00%s\x00%t\x00%t",
		j.file, j.name.Repr(), strings.Join(names, ","), j.hasScriptsRepo, j.usesScripts)
}

// entry is one item of a job's expanded step list: a resolved template, or a step.
type entry struct {
	template string
	step     *yamldoc.Node
}

// expander expands templates, recording every one it cannot read instead of
// swallowing it. Returning nothing quietly on a parse error would make the
// whole check self-defeating: a malformed template or an include pointing at
// nothing expands to no jobs, so every assertion finds nothing to complain
// about and the suite goes green PRECISELY WHEN IT HAS STOPPED LOOKING.
type expander struct {
	root        string
	scriptsRepo string
	// documents caches every template read, nil for one that cannot be read.
	documents   map[string]*yamldoc.Node
	unparseable []problem
	missing     []problem
	jobs        []job
}

// expandAll expands every job under `root`/azure-devops and writes the findings.
func expandAll(root string, output io.Writer) error {
	absolute, err := filepath.Abs(root)
	if err != nil {
		return err
	}
	templates := filepath.Join(absolute, "azure-devops")
	e := &expander{
		root:        absolute,
		scriptsRepo: filepath.Join(templates, "global", "abstracts", "scripts-repo.yaml"),
		documents:   map[string]*yamldoc.Node{},
	}
	err = filetext.Walk(templates, nil, func(path string) error {
		if strings.HasSuffix(path, ".yaml") || strings.HasSuffix(path, ".yml") {
			if document := e.load(path, ""); document != nil {
				e.collect(document, path)
			}
		}
		return nil
	})
	if err != nil {
		return err
	}
	return e.report(output)
}

// load parses a template once. `referencedFrom` is the template whose include
// named it, so a missing file is reported against the only place a human can
// fix it.
func (e *expander) load(path, referencedFrom string) *yamldoc.Node {
	if document, seen := e.documents[path]; seen {
		return document
	}
	e.documents[path] = nil // also guards include cycles
	if _, err := os.Stat(path); errors.Is(err, fs.ErrNotExist) {
		if referencedFrom != "" {
			e.missing = append(e.missing, problem{file: referencedFrom, detail: path})
		}
		return nil
	}
	document, err := yamldoc.Load(path, yamldoc.Options{})
	if err != nil {
		e.unparseable = append(
			e.unparseable,
			problem{file: path, detail: strings.Join(strings.Fields(err.Error()), " ")},
		)
		return nil
	}
	e.documents[path] = document
	return document
}

// resolve turns a `template:` reference into a local path. `path@repo` names a
// template in ANOTHER repository resource, which this repository can neither
// expand nor report as missing, so it resolves to nothing.
func resolve(reference *yamldoc.Node, base string) (string, bool) {
	text := reference.Str()
	if strings.Contains(text, "@") {
		return "", false
	}
	if filepath.IsAbs(text) {
		return filepath.Clean(text), true
	}
	return filepath.Join(filepath.Dir(base), text), true
}

// flatten lists the real entries of a list, unwrapping `${{ if ... }}:` and
// `${{ each ... }}:`. Those wrappers are ordinary YAML keys, so a naive walk sees
// a one-key mapping where a job or a step should be and skips the whole block --
// which is how `test:validate`, the only one of the three defects sitting inside
// an `${{ if }}`, hid from the first version of this check.
func flatten(entries *yamldoc.Node) []*yamldoc.Node {
	var found []*yamldoc.Node
	for _, item := range entries.Items() {
		if pairs := item.Pairs(); len(pairs) == 1 && isExpression(pairs[0].Key) {
			switch pairs[0].Value.Kind() {
			case yamldoc.Sequence:
				found = append(found, flatten(pairs[0].Value)...)
			case yamldoc.Mapping:
				found = append(found, pairs[0].Value)
			case yamldoc.Null, yamldoc.Bool, yamldoc.Int, yamldoc.Float, yamldoc.String:
			}
			continue
		}
		if item.Kind() == yamldoc.Mapping {
			found = append(found, item)
		}
	}
	return found
}

func isExpression(key *yamldoc.Node) bool {
	return key.IsString() && strings.HasPrefix(strings.TrimSpace(key.Text()), "${{")
}

// expand lists a job's fully expanded steps, following each step template.
func (e *expander) expand(steps *yamldoc.Node, base string, chain map[string]bool) []entry {
	var expanded []entry
	for _, step := range flatten(steps) {
		template := step.Get("template")
		if !template.Truthy() {
			expanded = append(expanded, entry{step: step})
			continue
		}
		path, local := resolve(template, base)
		if !local {
			continue
		}
		expanded = append(expanded, entry{template: path})
		if chain[path] { // a cycle would otherwise recurse forever
			continue
		}
		document := e.load(path, base)
		if document.Kind() == yamldoc.Mapping && document.Has("steps") {
			next := map[string]bool{path: true}
			for link := range chain {
				next[link] = true
			}
			expanded = append(expanded, e.expand(document.Get("steps"), path, next)...)
		}
	}
	return expanded
}

// collect records every job a template declares, following job templates.
func (e *expander) collect(node *yamldoc.Node, base string) {
	for _, item := range node.Items() {
		e.collect(item, base)
	}
	for _, pair := range node.Pairs() {
		if !pair.Key.Is("jobs") || pair.Value.Kind() != yamldoc.Sequence {
			e.collect(pair.Value, base)
			continue
		}
		for _, declared := range flatten(pair.Value) {
			switch {
			case declared.Has("job"):
				e.jobs = append(e.jobs, e.expandJob(declared, base))
			case declared.Has("template"):
				path, local := resolve(declared.Get("template"), base)
				if !local {
					continue
				}
				if document := e.load(path, base); document != nil {
					e.collect(document, path)
				}
			}
		}
	}
}

func (e *expander) expandJob(declared *yamldoc.Node, base string) job {
	found := job{file: e.relative(base), name: declared.Get("job"), duplicates: map[string]int{}}
	counts := map[string]int{}
	for _, item := range e.expand(declared.Get("steps"), base, map[string]bool{base: true}) {
		if item.step == nil {
			found.hasScriptsRepo = found.hasScriptsRepo || item.template == e.scriptsRepo
			continue
		}
		if name := item.step.Get("name"); name.IsString() && name.Text() != "" {
			counts[name.Text()]++
		}
		found.usesScripts = found.usesScripts || mentionsScriptsDirectory(item.step)
	}
	for name, count := range counts {
		if count > 1 {
			found.duplicates[name] = count
		}
	}
	return found
}

// mentionsScriptsDirectory reports whether any string of a step -- a key, or a
// value with its whole-line shell comments removed -- uses the variable. The
// comments go first: an abstract that merely EXPLAINS `$(Scripts.Directory)`
// ("there is no $(Scripts.Directory) to source the manifest from yet") must not
// count as using it.
func mentionsScriptsDirectory(node *yamldoc.Node) bool {
	switch node.Kind() {
	case yamldoc.String:
		return strings.Contains(filetext.StripComments(node.Text()), scriptsDirectory)
	case yamldoc.Mapping:
		for _, pair := range node.Pairs() {
			if strings.Contains(pair.Key.Str(), scriptsDirectory) || mentionsScriptsDirectory(pair.Value) {
				return true
			}
		}
	case yamldoc.Sequence:
		if slices.ContainsFunc(node.Items(), mentionsScriptsDirectory) {
			return true
		}
	case yamldoc.Null, yamldoc.Bool, yamldoc.Int, yamldoc.Float:
	}
	return false
}

func (e *expander) relative(path string) string {
	relative, err := filepath.Rel(e.root, path)
	if err != nil {
		return path
	}
	return relative
}

// report writes the findings: the unreadable templates first, since they
// invalidate the two assertions after them.
func (e *expander) report(output io.Writer) error {
	var lines []string
	for _, found := range e.unparseable {
		lines = append(lines, fmt.Sprintf("unreadable\t%s: unparseable (%s)", e.relative(found.file), found.detail))
	}
	for _, found := range e.missing {
		lines = append(lines, fmt.Sprintf("unreadable\t%s: missing include (%s)",
			e.relative(found.file), e.relative(found.detail)))
	}
	seen := map[string]bool{}
	for _, found := range e.jobs {
		if seen[found.key()] {
			continue
		}
		seen[found.key()] = true
		names := make([]string, 0, len(found.duplicates))
		for name := range found.duplicates {
			names = append(names, name)
		}
		sort.Strings(names)
		for _, name := range names {
			lines = append(lines, fmt.Sprintf("duplicate\t%s: job %s declares the step name %s %d times",
				found.file, found.name.Str(), yamldoc.Quote(name), found.duplicates[name]))
		}
		if found.usesScripts && !found.hasScriptsRepo {
			lines = append(lines, fmt.Sprintf("scripts\t%s: job %s uses %s but never includes scripts-repo",
				found.file, found.name.Str(), scriptsDirectory))
		}
	}
	for _, line := range lines {
		if _, err := fmt.Fprintln(output, line); err != nil {
			return err
		}
	}
	return nil
}
