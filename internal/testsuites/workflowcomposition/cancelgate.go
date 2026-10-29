package main

import (
	"fmt"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"unicode/utf8"
)

// Test 15: a job gated on a status function does not start on a cancelled run. The `if:` is split
// into top-level `||` clauses and each clause into top-level `&&` conjuncts, outside parentheses
// and quoted strings; every clause must carry `!cancelled()` or `success()` as a conjunct of its
// OWN, both of which are false on a cancelled run. An `if:` calling no status function is safe,
// because GitHub prepends `success()` to it, and a clause selecting `failure()` or `cancelled()`
// runs after one by design.

var (
	quotedString = regexp.MustCompile(`'(?:[^']|'')*'`)
	// statusCall is a status function after any non-word character; [boundary] supplies the `\b`
	// before it. Function names are case-insensitive in GitHub expressions.
	statusCall       = regexp.MustCompile(`^(?i:success|failure|cancelled|always)` + space + `*\(` + space + `*\)`)
	wrappedCondition = regexp.MustCompile(`^\$\{\{(.*)\}\}$`)
)

// cancelGuards are false on a cancelled run, so either one as a conjunct makes its clause false;
// the selectors pick a non-success outcome on purpose.
func cancelGuards() []string {
	return []string{"!cancelled()", "success()", "failure()", "cancelled()"}
}

// cancelCanary is a condition and whether it is safe on a cancelled run.
type cancelCanary struct {
	expression string
	safe       bool
}

// cancelCanaries run the classifier against the gate every delivery job carried, verbatim, and the
// shapes a "tidy these conditions" pass produces, so a parser that stops matching fails here
// instead of passing with nothing flagged.
func cancelCanaries() []cancelCanary {
	return []cancelCanary{
		{"!failure() && ((github.event_name == 'push' && github.ref == 'refs/heads/main') || " +
			"github.event_name == 'workflow_dispatch' || startsWith(github.ref, 'refs/tags/'))", false},
		{"inputs.build_web && !failure() && (github.event_name == 'push')", false},
		{"always() && github.ref == 'refs/heads/main'", false},
		{"!failure() && (!cancelled() || github.event_name == 'push')", false},
		{"(success() && github.ref == 'refs/heads/main') || startsWith(github.ref, 'refs/tags/')", false},
		{"!success() && github.ref == 'refs/heads/main'", false},
		{"!failure() && contains(github.ref, '!cancelled() || x')", false},
		{"!cancelled() && !failure() && ((github.event_name == 'push' && github.ref == " +
			"'refs/heads/main') || startsWith(github.ref, 'refs/tags/'))", true},
		{"inputs.build_web && !cancelled() && !failure() && (github.event_name == 'push')", true},
		{"(success() && github.ref == 'refs/heads/main') || " +
			"(!cancelled() && startsWith(github.ref, 'refs/tags/'))", true},
		{"${{ ! Cancelled( ) && !failure() }}", true},
		{"github.event_name == 'push'", true},
		{"failure() && github.ref == 'refs/heads/main'", true},
	}
}

func checkCancelGate(directory string, out *printer) error {
	examined := 0
	for _, name := range globFiles(directory, "*.yaml") {
		document, err := loadFile(filepath.Join(directory, name), standardYAML)
		if err != nil {
			out.line(fmt.Sprintf("%s: unreadable (%v)", name, err))
			continue
		}
		counted, err := cancelGates(document, func(job, clause string) {
			out.line(fmt.Sprintf("%s: job %s still starts on a cancelled run -- `%s` has no `!cancelled()` or "+
				"`success()` of its own; write `!cancelled() && !failure() && (...)`", name, job, clause))
		})
		examined += counted
		if err != nil {
			out.line(name + ": " + err.Error())
		}
	}
	if examined == 0 {
		out.line(fmt.Sprintf("no job under %s gates on a status function -- the scan read nothing", directory))
	}
	for _, canary := range cancelCanaries() {
		if (len(unguarded(canary.expression)) == 0) != canary.safe {
			verdict, truth := "unsafe", "safe"
			if !canary.safe {
				verdict, truth = "safe", "not"
			}
			out.line(fmt.Sprintf("the classifier calls `%s` %s on a cancelled run, but it is %s",
				canary.expression, verdict, truth))
		}
	}
	return nil
}

// cancelGates reports every unguarded clause of every job's `if:` and returns how many of the
// conditions it read call a status function.
func cancelGates(document *value, report func(job, clause string)) (int, error) {
	examined := 0
	err := eachJob(document, func(job string, body *value) error {
		condition := body.get("if")
		if condition.is(nullKind) {
			return nil
		}
		if callsStatus(quotedString.ReplaceAllLiteralString(condition.str(), "''")) {
			examined++
		}
		for _, clause := range unguarded(condition.str()) {
			report(job, clause)
		}
		return nil
	})
	return examined, err
}

// callsStatus reports whether a status function is called anywhere in `text`, which has had its
// string literals emptied.
func callsStatus(text string) bool {
	for start := 0; start < len(text); {
		if boundary(text, start) && statusCall.MatchString(text[start:]) {
			return true
		}
		_, size := utf8.DecodeRuneInString(text[start:])
		start += size
	}
	return false
}

// unguarded is the clauses of a job `if:` that can still be TRUE on a cancelled run.
func unguarded(expression string) []string {
	expression = collapse(expression)
	if wrapped := wrappedCondition.FindStringSubmatch(expression); wrapped != nil {
		expression = strip(wrapped[1])
	}
	if !callsStatus(quotedString.ReplaceAllLiteralString(expression, "''")) {
		return nil // GitHub prepends `success()` itself
	}
	var found []string
	for _, clause := range clauses(expression) {
		if !guarded(clause) {
			found = append(found, clause)
		}
	}
	return found
}

// guarded reports whether one of a clause's own conjuncts is a guard or a deliberate selector.
func guarded(clause string) bool {
	for _, term := range splitTop(stripParens(clause), "&&") {
		if slices.Contains(cancelGuards(), canonical(term)) {
			return true
		}
	}
	return false
}

// scanTop calls `visit` with each byte offset of `expression` and whether the byte there sits at
// parenthesis depth 0 outside a quoted string. The state is updated before the byte is reported:
// an opening parenthesis is already inside its group, a closing one back outside it.
func scanTop(expression string, visit func(offset int, character byte, top bool)) {
	depth, quoted := 0, false
	for offset := range len(expression) {
		character := expression[offset]
		switch {
		case character == '\'':
			quoted = !quoted // a doubled `''` toggles twice, which is right
		case !quoted && character == '(':
			depth++
		case !quoted && character == ')':
			depth--
		}
		visit(offset, character, depth == 0 && !quoted)
	}
}

// splitTop splits an expression on `operator` where it sits at depth 0 outside quotes, and drops
// the empty parts.
func splitTop(expression, operator string) []string {
	var parts []string
	start, skip := 0, 0
	scanTop(expression, func(offset int, _ byte, top bool) {
		if skip > 0 {
			skip--
			return
		}
		if top && strings.HasPrefix(expression[offset:], operator) {
			parts = append(parts, expression[start:offset])
			start, skip = offset+len(operator), len(operator)-1
		}
	})
	parts = append(parts, expression[start:])
	kept := parts[:0]
	for _, part := range parts {
		if part = strip(part); part != "" {
			kept = append(kept, part)
		}
	}
	return kept
}

// stripParens removes outer parentheses while they enclose the whole term.
func stripParens(term string) string {
	term = strip(term)
	for strings.HasPrefix(term, "(") && strings.HasSuffix(term, ")") {
		closes, last := 0, -1
		scanTop(term, func(offset int, character byte, top bool) {
			if top && character == ')' {
				closes++
				last = offset
			}
		})
		if closes != 1 || last != len(term)-1 {
			break
		}
		term = strip(term[1 : len(term)-1])
	}
	return term
}

// canonical is a conjunct without whitespace, lower-cased and unwrapped, with a leading `!` kept
// outside the parentheses it negates: `! ( Cancelled( ) )` is `!cancelled()`.
func canonical(term string) string {
	term = stripParens(strings.ToLower(strings.Map(func(character rune) rune {
		if isSpace(character) {
			return -1
		}
		return character
	}, term)))
	if rest, negated := strings.CutPrefix(term, "!"); negated {
		return "!" + stripParens(rest)
	}
	return term
}

// clauses is the top-level `||` clauses of an expression, recursing through redundant outer
// parentheses.
func clauses(expression string) []string {
	parts := splitTop(stripParens(expression), "||")
	if len(parts) == 1 {
		return parts
	}
	var found []string
	for _, part := range parts {
		found = append(found, clauses(part)...)
	}
	return found
}
