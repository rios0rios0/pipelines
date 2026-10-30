package main

import (
	"fmt"
	"path/filepath"
	"regexp"
	"strings"
	"unicode"

	"github.com/rios0rios0/pipelines/internal/testsuites/filetext"
)

// gate is the condition every `$HOME` cache must carry. It is written against
// `self-hosted` on purpose: a `runner.environment` that resolves to neither value
// (an empty string on an older runner, a future third value) must keep the cache
// ON for hosted consumers rather than silently disabling it for everyone.
const gate = "runner.environment != 'self-hosted'"

// indentStep is how much deeper a mapping's keys sit than the dash of the
// sequence item holding it.
const indentStep = 2

var (
	// antiGate is the inverted gate, in either quote style. GitHub Actions
	// expressions only accept SINGLE quotes -- the double-quoted form is a parse
	// error, so it cannot ship silently -- but matching both keeps the
	// diagnostic honest about what it looks for.
	antiGate = regexp.MustCompile(`runner\.environment[[:space:]]*==[[:space:]]*['"]github-hosted['"]`)
	setupGo  = regexp.MustCompile(`actions/setup-go@`)
	cache    = regexp.MustCompile(`actions/cache(?:/restore|/save)?@`)
	// homePath is a `~/…` or `$HOME/…` entry -- the paths a self-hosted runner
	// keeps between jobs. A path that resolves there through a variable is not
	// matched and does not need to be: see the suite's header.
	homePath = regexp.MustCompile(`^[[:space:]]*(?:-[[:space:]]*)?['"]?(?:~|\$HOME|\$\{HOME\})/`)
	// sequenceItem is a line that opens a YAML sequence item.
	sequenceItem = regexp.MustCompile(`^([[:space:]]*)-[[:space:]]+[^[:space:]]`)
	// itemHeadKey is the key a sequence item opens with, on its dash line.
	itemHeadKey = regexp.MustCompile(`^[[:space:]]*-[[:space:]]+([A-Za-z_-]+):[[:space:]]*(.*)$`)
	// stepKey is one of a step's own keys.
	stepKey = regexp.MustCompile(`^[[:space:]]*([A-Za-z_-]+):[[:space:]]*(.*)$`)
	// withKey is one key of a step's `with:` map.
	withKey = regexp.MustCompile(`^[[:space:]]*([A-Za-z_.-]+):[[:space:]]*(.*)$`)
)

// item is one YAML sequence item: its first and past-last line, and the
// indentation its keys sit at.
type item struct {
	start, end, keyIndent int
}

// indentOf is how many spaces a line starts with.
func indentOf(line string) int {
	return len(line) - len(strings.TrimLeft(line, " "))
}

// skippable reports whether a line says nothing about structure: blank, or a comment.
func skippable(line string) bool {
	return strings.TrimSpace(line) == "" || filetext.IsComment(line)
}

// items finds every sequence item: from its dash line to the first line that
// says something and is indented no deeper than the dash.
func items(lines []string) []item {
	var found []item
	for start, line := range lines {
		match := sequenceItem.FindStringSubmatch(line)
		if match == nil {
			continue
		}
		dashIndent := len(match[1])
		end := len(lines)
		for next := start + 1; next < len(lines); next++ {
			if skippable(lines[next]) {
				continue
			}
			if indentOf(lines[next]) <= dashIndent {
				end = next
				break
			}
		}
		found = append(found, item{start: start, end: end, keyIndent: dashIndent + indentStep})
	}
	return found
}

// keysOf maps an item's own top-level keys to their raw value text. `- uses: 'x'`
// puts the first key on the dash line itself.
func keysOf(lines []string, step item) map[string]string {
	keys := map[string]string{}
	if head := itemHeadKey.FindStringSubmatch(lines[step.start]); head != nil {
		keys[head[1]] = strings.TrimSpace(head[2])
	}
	for index := step.start + 1; index < step.end; index++ {
		if indentOf(lines[index]) != step.keyIndent {
			continue
		}
		if match := stepKey.FindStringSubmatch(lines[index]); match != nil {
			keys[match[1]] = strings.TrimSpace(match[2])
		}
	}
	return keys
}

// withOf maps the keys of an item's `with:` to their raw value text, and to the
// lines of the block each one opens.
func withOf(lines []string, step item) (map[string]string, map[string][]string) {
	values, blocks := map[string]string{}, map[string][]string{}
	opening := -1
	for index := step.start + 1; index < step.end; index++ {
		if indentOf(lines[index]) == step.keyIndent &&
			strings.HasPrefix(strings.TrimLeftFunc(lines[index], unicode.IsSpace), "with:") {
			opening = index
			break
		}
	}
	if opening < 0 {
		return values, blocks
	}
	inner := step.keyIndent + indentStep
	current, open := "", false
	for index := opening + 1; index < step.end; index++ {
		line := lines[index]
		if skippable(line) {
			continue
		}
		if indentOf(line) < inner {
			break
		}
		if indentOf(line) == inner {
			if match := withKey.FindStringSubmatch(line); match != nil {
				current, open = match[1], true
				values[current] = strings.TrimSpace(match[2])
				blocks[current] = nil
				continue
			}
		}
		if open {
			blocks[current] = append(blocks[current], line)
		}
	}
	return values, blocks
}

// scan reports every violation in the YAML files under `root`.
func scan(root string) ([]string, error) {
	var findings []string
	err := filetext.Walk(root, func(name string) bool { return name == ".git" }, func(path string) error {
		if !strings.HasSuffix(path, ".yaml") && !strings.HasSuffix(path, ".yml") {
			return nil
		}
		text, err := filetext.Read(path)
		if err != nil {
			return err
		}
		relative, err := filepath.Rel(root, path)
		if err != nil {
			return err
		}
		findings = append(findings, scanFile(relative, filetext.Lines(text))...)
		return nil
	})
	return findings, err
}

func scanFile(relative string, lines []string) []string {
	var findings []string
	for _, step := range items(lines) {
		keys := keysOf(lines, step)
		uses := keys["uses"]
		if uses == "" {
			continue
		}
		values, blocks := withOf(lines, step)
		where := fmt.Sprintf("%s:%d", relative, step.start+1)
		if setupGo.MatchString(uses) {
			findings = append(findings, setupGoFindings(where, values)...)
		}
		if cache.MatchString(uses) && namesHomePath(values, blocks) && !strings.Contains(keys["if"], gate) {
			findings = append(findings, fmt.Sprintf(
				"%s: actions/cache names a $HOME path but is not gated -- add `if: \"%s\"`.", where, gate))
		}
		for _, check := range []struct{ label, text string }{{"if", keys["if"]}, {"cache", values["cache"]}} {
			if check.text != "" && antiGate.MatchString(check.text) {
				findings = append(findings, fmt.Sprintf("%s: gated on `== 'github-hosted'` (%s), which disables the "+
					"cache for every consumer whose runner reports neither value. Write `!= 'self-hosted'`.",
					where, check.label))
			}
		}
	}
	return findings
}

func setupGoFindings(where string, values map[string]string) []string {
	setting, set := values["cache"]
	switch {
	case !set:
		return []string{fmt.Sprintf("%s: actions/setup-go leaves `cache` at its default (on), so a self-hosted "+
			"runner downloads GOMODCACHE over itself and discards it. Set `cache: ${{ %s }}`.", where, gate)}
	case setting != "false" && !strings.Contains(setting, gate):
		return []string{fmt.Sprintf("%s: actions/setup-go has `cache: %s`, which is neither `false` nor gated on `%s`.",
			where, setting, gate)}
	}
	return nil
}

// namesHomePath reports whether a cache's `path:` names a `$HOME` path, on its
// own line or in the block it opens.
func namesHomePath(values map[string]string, blocks map[string][]string) bool {
	for _, entry := range append([]string{values["path"]}, blocks["path"]...) {
		if entry != "" && homePath.MatchString(entry) {
			return true
		}
	}
	return false
}
