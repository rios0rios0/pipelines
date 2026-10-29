package main

import (
	"fmt"
	"path/filepath"
	"strings"
)

// Test 12: no trigger-block `description:` or `default:` carries an evaluated expression. GitHub
// EVALUATES `${{ }}` in those fields, and the trigger block has no context, so an example naming
// `github` there makes the whole file fail to compile.

// evaluatedKey reports whether a trigger-block key is one of the documentation-shaped keys a human
// writes prose into. Every other scalar under `on:` (branch globs, paths, types) is data GitHub
// reads literally, so flagging these two names the defect instead of pattern-matching text.
func evaluatedKey(key *value) bool {
	return key.isString("description") || key.isString("default")
}

func checkOnExpressions(directory string, out *printer) error {
	for _, name := range globFiles(directory, "*.yaml") {
		document, err := loadFile(filepath.Join(directory, name), standardYAML)
		if err != nil {
			out.line(fmt.Sprintf("%s: unreadable (%v)", name, err))
			continue
		}
		events, err := trigger(document)
		if err != nil {
			out.line(name + ": " + err.Error())
			continue
		}
		walkEvaluated(events, "", func(location, text string) {
			if strings.Contains(text, "${{") {
				out.line(fmt.Sprintf("%s: on.%s contains an evaluated expression", name, location))
			}
		})
	}
	return nil
}

// walkEvaluated calls `visit` with the dotted path and text of every `description` or `default`
// string under `node`, in document order, descending into everything else.
func walkEvaluated(node *value, path string, visit func(location, text string)) {
	switch {
	case node.is(mappingKind):
		for _, entry := range node.pairs {
			child := entry.key.str()
			if path != "" {
				child = path + "." + child
			}
			if evaluatedKey(entry.key) && entry.value.is(stringKind) {
				visit(child, entry.value.text)
			} else {
				walkEvaluated(entry.value, child, visit)
			}
		}
	case node.is(sequenceKind):
		for index, item := range node.items {
			walkEvaluated(item, fmt.Sprintf("%s[%d]", path, index), visit)
		}
	}
}
