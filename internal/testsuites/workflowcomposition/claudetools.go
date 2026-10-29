package main

import (
	"fmt"
	"path/filepath"
	"regexp"
	"slices"
	"sort"
	"strings"
	"unicode/utf8"
)

// Test 13: the Claude prompts describe the tools those jobs actually grant. A granted Bash command
// missing from the prompt re-creates the defect the prompts exist to prevent (the model meets its
// own tools by being denied them), and a command the prompt calls denied while the allowlist
// grants it is the same drift reversed. Both halves read SENTENCES, because a prompt states an
// exclusion wherever it is clearest.

const (
	claudeAction = "anthropics/claude-code-action"
	// deniedMarker opens the paragraph where a prompt DECLARES its exclusions. Its presence is
	// required, but it is deliberately not where they are CHECKED: a denial reads as a sentence and
	// can be written anywhere.
	deniedMarker = "Denied on purpose:"
)

var (
	bashRule   = regexp.MustCompile(`Bash\(([^)]*)\)`)
	backticked = regexp.MustCompile("`([^`]+)`")
	paragraphs = regexp.MustCompile(`\n` + space + `*\n`)
)

// tagModeBash is what tag mode grants whatever `claude_args` says (`src/modes/tag/index.ts`), with
// `use_commit_signing` at its default `false` -- turning it on swaps these for the MCP file-ops
// tools. They are part of the surface a prompt has to describe, so they count as granted even
// though no file here names them.
func tagModeBash() []string {
	return []string{"git add", "git commit", "git rm"}
}

// denialPhrases make a sentence a denial. Deliberately narrow: "is refused as a whole" describes a
// REJECTED PIPE in a sentence that grants seven commands, and matching it would flag every one.
func denialPhrases() []string {
	return []string{"not granted", "neither is", "is not", "are not", "denied", "absent"}
}

func checkClaudeTools(directory string, out *printer) error {
	for _, name := range globFiles(directory, "reusable-claude-*.yaml") {
		document, err := loadFile(filepath.Join(directory, name), standardYAML)
		if err != nil {
			out.line(fmt.Sprintf("%s: unreadable (%v)", name, err))
			continue
		}
		if err = claudeSteps(document, func(step *value) error { return claudeStep(out, name, step) }); err != nil {
			out.line(name + ": " + err.Error())
		}
	}
	return nil
}

// claudeSteps calls `visit` with every step that runs the Claude action, in document order, and
// stops at the first job or step whose shape it cannot read.
func claudeSteps(document *value, visit func(step *value) error) error {
	return eachJob(document, func(job string, body *value) error {
		steps, err := sequenceOr(body.get("steps"), "`steps` of job "+job)
		if err != nil {
			return err
		}
		for index, item := range steps.items {
			var step *value
			if step, err = mappingOr(item, fmt.Sprintf("step %d of job %s", index+1, job)); err != nil {
				return err
			}
			uses := ""
			if step.has("uses") {
				uses = step.get("uses").str()
			}
			if !strings.HasPrefix(uses, claudeAction) {
				continue
			}
			if err = visit(step); err != nil {
				return err
			}
		}
		return nil
	})
}

func claudeStep(out *printer, name string, step *value) error {
	report := func(format string, arguments ...any) {
		out.line(name + ": " + fmt.Sprintf(format, arguments...))
	}
	inputs, err := mappingOr(step.get("with"), "the with: of the "+claudeAction+" step")
	if err != nil {
		return err
	}
	prompt := orText(inputs.get("prompt"))
	if strip(prompt) == "" {
		report("the %s step declares no prompt -- the action template then tells the model to install "+
			"dependencies and run builds", claudeAction)
		return nil
	}
	// The string spelling counts too: GitHub hands every input to the action as a string, so 'true'
	// runs identically and must not read as a missing pair.
	if strings.ToLower(inputs.get("track_progress").str()) != "true" {
		report("declares a prompt without `track_progress: true` -- a prompt on a comment or issue event " +
			"selects AGENT mode, replacing the template that answers the trigger")
	}
	granted := grantedCommands(orText(inputs.get("claude_args")))
	denials, positive := partitionSentences(prompt)
	for _, rule := range granted {
		// A prompt may name the rule as granted (`git add`) or name the broader grant that covers it
		// (`git`), in a sentence that is not itself a denial -- otherwise "`gh` is not granted" would
		// count as naming `gh`, which is the reading that let a stale denial pass for a description.
		if !namedAsHeld(positive, rule) {
			report("grants Bash(%s:*) but no sentence of the prompt names it as held -- the model meets its own "+
				"tools by being denied them", rule)
		}
	}
	if !slices.ContainsFunc(paragraphs.Split(prompt, -1), func(paragraph string) bool {
		return strings.Contains(paragraph, deniedMarker)
	}) {
		report(`the prompt has no "%s" paragraph -- nothing states that the toolchains are excluded by decision `+
			"rather than by oversight", deniedMarker)
	}
	for _, sentence := range denials {
		for _, token := range backticked.FindAllStringSubmatch(sentence, -1) {
			for _, rule := range coveringRules(granted, token[1]) {
				report("the prompt calls `%s` denied while the allowlist grants Bash(%s:*)", token[1], rule)
			}
		}
	}
	return nil
}

// grantedCommands is every Bash command the step holds, sorted: what tag mode grants, and the
// binary of every `Bash(...)` rule in `claude_args`.
func grantedCommands(claudeArguments string) []string {
	granted := slices.Clone(tagModeBash())
	for _, rule := range bashRule.FindAllStringSubmatch(claudeArguments, -1) {
		if command := commandWord(rule[1]); command != "" && !slices.Contains(granted, command) {
			granted = append(granted, command)
		}
	}
	sort.Strings(granted)
	return granted
}

// partitionSentences splits the prompt's sentences into the denials and the rest.
func partitionSentences(prompt string) ([]string, []string) {
	var denials, positive []string
	for _, sentence := range sentences(prompt) {
		if isDenial(sentence) {
			denials = append(denials, sentence)
		} else {
			positive = append(positive, sentence)
		}
	}
	return denials, positive
}

// coveringRules is the granted rules that make a denial of `token` false.
func coveringRules(granted []string, token string) []string {
	var found []string
	for _, rule := range granted {
		if covers(rule, token) {
			found = append(found, rule)
		}
	}
	return found
}

// orText is Python's `str(value or "")`: an absent or false value is the empty string.
func orText(v *value) string {
	if !v.truthy() {
		return ""
	}
	return v.str()
}

// commandWord is the binary a Bash rule permits: `git add:*` and `gh:*` give `git` and `gh`.
func commandWord(rule string) string {
	head, _, _ := strings.Cut(rule, ":")
	words := strings.FieldsFunc(head, isSpace)
	if len(words) == 0 {
		return ""
	}
	return words[0]
}

// sentences is every sentence of the prompt, unwrapped: `.` and `;` end one, and the prompts wrap
// at 88 columns, so the text is joined before it is split. `:` does not end one -- splitting on it
// would cut "Denied on purpose:" away from the list it introduces.
func sentences(prompt string) []string {
	text := collapse(prompt)
	var found []string
	start := 0
	for index := 1; index < len(text); index++ {
		if text[index] == ' ' && (text[index-1] == '.' || text[index-1] == ';') {
			found = append(found, text[start:index])
			start = index + 1
		}
	}
	if start < len(text) {
		found = append(found, text[start:])
	}
	return found
}

// isDenial reports whether a sentence holds one of the denial phrases as whole words, in any case.
func isDenial(sentence string) bool {
	for start := 0; start < len(sentence); {
		if boundary(sentence, start) {
			for _, phrase := range denialPhrases() {
				if end, ok := prefixFold(sentence, start, phrase); ok && boundary(sentence, end) {
					return true
				}
			}
		}
		_, size := utf8.DecodeRuneInString(sentence[start:])
		start += size
	}
	return false
}

// prefixFold reports whether `text` holds `phrase` at byte offset `start`, ignoring case, and where
// the match ends.
func prefixFold(text string, start int, phrase string) (int, bool) {
	at := start
	for _, want := range phrase {
		if at >= len(text) {
			return 0, false
		}
		got, size := utf8.DecodeRuneInString(text[at:])
		if !strings.EqualFold(string(got), string(want)) {
			return 0, false
		}
		at += size
	}
	return at, true
}

// namedAsHeld reports whether a sentence that is not a denial names `rule`, or the binary it is a
// subcommand of, in backticks.
func namedAsHeld(positive []string, rule string) bool {
	spellings := []string{rule, strings.Fields(rule)[0]}
	for _, sentence := range positive {
		for _, spelling := range spellings {
			if strings.Contains(sentence, "`"+spelling+"`") {
				return true
			}
		}
	}
	return false
}

// covers reports whether granting `rule` makes a denial of `token` false: a granted `git` covers
// `git diff`, and a granted `git add` does not -- which is what keeps the mention responder's true
// `git diff` sentence from reading as a collision.
func covers(rule, token string) bool {
	return token == rule || strings.HasPrefix(token, rule+" ")
}
