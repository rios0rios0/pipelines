package main

import (
	"fmt"
	"io"
	"strings"

	"github.com/rios0rios0/pipelines/internal/testsuites/yamldoc"
)

// step is one place an Azure template hands the agent a script body.
type step struct {
	file        string
	displayName *yamldoc.Node
	script      *yamldoc.Node
	inputs      *yamldoc.Node
	env         *yamldoc.Node
}

// collectSteps finds every step-shaped mapping in a template, wrappers
// included. `${{ if }}:` and `${{ each }}:` blocks are ordinary YAML keys, so a
// walk that only follows known keys skips whatever they contain; recursing
// through every value instead means a step inside a conditional is still seen.
func collectSteps(node *yamldoc.Node, file string, steps *[]step) {
	switch node.Kind() {
	case yamldoc.Mapping:
		shellKey := shellKeyOf(node)
		if shellKey != "" || (node.Has("task") && node.Has("inputs")) {
			found := step{
				file:        file,
				displayName: node.Get("displayName"),
				inputs:      node.Get("inputs"),
				env:         node.Get("env"),
			}
			if shellKey != "" {
				found.script = node.Get(shellKey)
			}
			*steps = append(*steps, found)
			// A task carries its shell under `inlineScript:`/`script:`, which Azure
			// macro-expands exactly like a bare `script:` step.
			if inline := inlineScript(node.Get("inputs")); inline != nil {
				*steps = append(*steps, step{
					file:        file,
					displayName: node.Get("displayName"),
					script:      inline,
					env:         node.Get("env"),
				})
			}
		}
		for _, pair := range node.Pairs() {
			collectSteps(pair.Value, file, steps)
		}
	case yamldoc.Sequence:
		for _, item := range node.Items() {
			collectSteps(item, file, steps)
		}
	case yamldoc.Null, yamldoc.Bool, yamldoc.Int, yamldoc.Float, yamldoc.String:
	}
}

// shellKeyOf is the first shell shortcut a mapping carries, or "".
func shellKeyOf(node *yamldoc.Node) string {
	for _, key := range shellKeys() {
		if node.Has(key) {
			return key
		}
	}
	return ""
}

// inlineScript is the script a task's inputs carry, or nil.
func inlineScript(inputs *yamldoc.Node) *yamldoc.Node {
	if inputs.Kind() != yamldoc.Mapping {
		return nil
	}
	inline := inputs.Get("inlineScript")
	if !inline.Truthy() {
		inline = inputs.Get("script")
	}
	if !inline.IsString() {
		return nil
	}
	return inline
}

// key names the step for the declared and exempt tables, which only a string
// displayName can match.
func (s step) key() (stepKey, bool) {
	if !s.displayName.IsString() {
		return stepKey{}, false
	}
	return stepKey{file: s.file, displayName: s.displayName.Text()}, true
}

// label is how a finding names the step.
func (s step) label() string {
	if s.displayName.Truthy() {
		return s.displayName.Repr()
	}
	return yamldoc.Quote("<unnamed>")
}

// scriptText is the step's script when it is a string: the text whose
// whole-line comments are not read.
func (s step) scriptText() string {
	return s.script.Text()
}

// otherStrings are the rest of what the agent hands over and the step can
// read: a script that is not a string, and the task's inputs. They are read
// whole, comments and all.
func (s step) otherStrings() []string {
	var texts []string
	if !s.script.IsString() && s.script.Truthy() {
		texts = append(texts, s.script.Strings()...)
	}
	if s.inputs.Truthy() {
		texts = append(texts, s.inputs.Strings()...)
	}
	return texts
}

// mentions reports whether the step names `path` -- a script it runs.
func (s step) mentions(path string, others []string) bool {
	if strings.Contains(s.scriptText(), path) {
		return true
	}
	for _, text := range others {
		if strings.Contains(text, path) {
			return true
		}
	}
	return false
}

// mappedNames are the variables the step maps through `env:`.
func (s step) mappedNames() map[string]bool {
	names := map[string]bool{}
	for _, pair := range s.env.Pairs() {
		if pair.Key.IsString() {
			names[pair.Key.Text()] = true
		}
	}
	for _, item := range s.env.Items() {
		if item.IsString() {
			names[item.Text()] = true
		}
	}
	return names
}

// stepScript writes the script of every step named `displayName` in the job
// `job` of the stage template at `path`.
func stepScript(path, job, displayName string, output io.Writer) error {
	document, err := yamldoc.Load(path, yamldoc.Options{})
	if err != nil {
		return fmt.Errorf("%s: %w", path, err)
	}
	stages := document.Get("stages")
	if stages.Kind() != yamldoc.Sequence {
		return fmt.Errorf("%s: no `stages:` list", path)
	}
	for _, found := range namedSteps(stages, job, displayName) {
		script := found.Get("script")
		if !script.IsString() {
			return fmt.Errorf("%s: the step %s has no `script:`", path, yamldoc.Quote(displayName))
		}
		if _, err = io.WriteString(output, script.Text()); err != nil {
			return err
		}
	}
	return nil
}

// namedSteps are the steps named `displayName` in every job `job` of `stages`.
func namedSteps(stages *yamldoc.Node, job, displayName string) []*yamldoc.Node {
	var found []*yamldoc.Node
	for _, stage := range stages.Items() {
		for _, candidate := range stage.Get("jobs").Items() {
			if !candidate.Get("job").Is(job) {
				continue
			}
			for _, item := range candidate.Get("steps").Items() {
				if item.Get("displayName").Is(displayName) {
					found = append(found, item)
				}
			}
		}
	}
	return found
}
