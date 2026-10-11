package entities

import (
	"regexp"
	"slices"
	"strings"
)

// customLinterPattern is golangci-lint's custom-linter block. A custom linter
// is a plugin -- code that runs inside every consumer's lint job -- so a
// configuration that starts declaring one is never adopted without a person.
var customLinterPattern = regexp.MustCompile(`(?m)^\s+custom:\s*(#.*)?$`)

// Indentation of the keys the enabled-linter scan reads.
const (
	topLevelIndent = 0
	sectionIndent  = 2
)

// DeclaresPlugin is true when a golangci-lint configuration declares a custom
// linter plugin.
func DeclaresPlugin(configuration string) bool {
	return customLinterPattern.MatchString(configuration)
}

// EnabledLinters lists what a golangci-lint configuration enables: every
// linter under `linters.enable`, and every formatter under `formatters.enable`
// marked as one.
func EnabledLinters(configuration string) []string {
	var (
		enabled  []string
		section  string
		inEnable bool
	)
	for raw := range strings.Lines(configuration) {
		line := strings.TrimRight(raw, "\r\n")
		content := strings.TrimSpace(line)
		if content == "" || strings.HasPrefix(content, "#") {
			continue
		}
		switch indent := len(line) - len(strings.TrimLeft(line, " ")); {
		case indent == topLevelIndent:
			section = ""
			if content == "linters:" || content == "formatters:" {
				section = strings.TrimSuffix(content, ":")
			}
			inEnable = false
		case indent == sectionIndent && section != "":
			inEnable = content == "enable:"
		case inEnable && strings.HasPrefix(content, "- "):
			name := strings.Fields(strings.TrimPrefix(content, "- "))[0]
			if section == "formatters" {
				name += " (formatter)"
			}
			enabled = append(enabled, name)
		}
	}
	return enabled
}

// LinterChanges is what moving a configuration from `base` to `proposed`
// switches on and off.
func LinterChanges(base, proposed string) ([]string, []string) {
	before, after := EnabledLinters(base), EnabledLinters(proposed)
	switchedOn := slices.DeleteFunc(
		slices.Clone(after),
		func(name string) bool { return slices.Contains(before, name) },
	)
	switchedOff := slices.DeleteFunc(
		slices.Clone(before),
		func(name string) bool { return slices.Contains(after, name) },
	)
	return switchedOn, switchedOff
}
