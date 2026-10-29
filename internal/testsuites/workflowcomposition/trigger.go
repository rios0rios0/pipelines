package main

import (
	"cmp"
	"encoding/json"
	"fmt"
	"math/big"
	"path/filepath"
	"regexp"
	"slices"
	"sort"
	"strings"
)

// Test 11: the mention responder's trigger guard reads the right author. The `if:` is split into
// its top-level `||` clauses, and each clause reading an `author_association` must also carry the
// null-check selecting the payload it belongs to -- the `issue` clause must additionally exclude
// comment events -- and must read it against exactly the privileged associations.

const (
	mentionWorkflow = "reusable-claude-mention.yaml"
	// jsonWhitespace is what JSON allows after a value, and so all `json.loads` allowed there.
	jsonWhitespace = " \t\n\r"
	// decimalBase is the base a JSON integer is written in.
	decimalBase = 10
)

var (
	authorAssociation = regexp.MustCompile(`github\.event\.(` + word + `+)\.author_association`)
	associationList   = regexp.MustCompile(
		`contains\(` + space + `*fromJSON\(` + space + `*'(\[[^']*\])'` + space + `*\)`)
)

// commentExclusions are the two spellings that keep an `issue_comment` payload, which carries both
// `comment` and `issue`, out of a clause.
func commentExclusions() []string {
	return []string{"github.event.comment == null", "github.event_name == 'issues'"}
}

// privilegedAssociations is the allowlist every clause must read an association against, sorted.
// Adding `CONTRIBUTOR` or `NONE` is one token inside the same free-text block, and it opens the job
// to anyone who has landed a commit -- or to anyone at all -- while every pairing check passes.
func privilegedAssociations() []string {
	return []string{"COLLABORATOR", "MEMBER", "OWNER"}
}

func checkTrigger(directory string, out *printer) error {
	document, err := loadFile(filepath.Join(directory, mentionWorkflow), standardYAML)
	if err != nil {
		out.line(fmt.Sprintf("%s: unreadable (%v)", mentionWorkflow, err))
		return nil
	}
	if err = triggerGuards(document, out); err != nil {
		out.line(mentionWorkflow + ": " + err.Error())
	}
	return nil
}

func triggerGuards(document *value, out *printer) error {
	return eachJob(document, func(job string, body *value) error {
		condition := ""
		if body.has("if") {
			condition = collapse(body.get("if").str())
		}
		if condition == "" {
			out.line(fmt.Sprintf("%s: job %s has no `if:` -- the trigger is unguarded", mentionWorkflow, job))
			return nil
		}
		for _, clause := range orClauses(condition) {
			guardClause(out, job, clause)
		}
		return nil
	})
}

// guardClause checks one top-level clause of the responder's `if:`.
func guardClause(out *printer, job, clause string) {
	report := func(format string, arguments ...any) {
		out.line(mentionWorkflow + ": " + fmt.Sprintf(format, arguments...))
	}
	var authors []string
	for _, match := range authorAssociation.FindAllStringSubmatch(clause, -1) {
		if !slices.Contains(authors, match[1]) {
			authors = append(authors, match[1])
		}
	}
	sort.Strings(authors)
	if len(authors) == 0 {
		report("job %s has a clause reading no author_association: %s", job, clause)
		return
	}
	if len(authors) > 1 {
		// `orClauses` splits at parenthesis depth 0, which only separates the clauses while each is
		// itself parenthesised. Wrap the expression and every `||` sits at depth 1, the split returns
		// ONE clause, and every check below degrades to "present somewhere in the expression" while
		// still passing. That is this assertion's own threat model, so the assumption is checked.
		report("job %s has one clause reading %d payload associations %s -- the top-level `||` split did not "+
			"separate them, so the null-check pairing is unverified", job, len(authors), reprStrings(authors))
		return
	}
	for _, match := range associationList.FindAllStringSubmatch(clause, -1) {
		allowed, err := associationsOf(match[1])
		if err != nil {
			report("job %s has an association list that is not JSON: %s", job, match[1])
			continue
		}
		if allowed.repr() != reprStrings(privilegedAssociations()) {
			report("job %s admits %s -- the trigger allowlist must be exactly %s",
				job, allowed.repr(), reprStrings(privilegedAssociations()))
		}
	}
	author := authors[0]
	if !strings.Contains(clause, "github.event."+author+" != null") {
		report("job %s reads %s.author_association without requiring github.event.%s != null", job, author, author)
	}
	if author == "issue" && !slices.ContainsFunc(commentExclusions(), func(exclusion string) bool {
		return strings.Contains(clause, exclusion)
	}) {
		report("job %s reads the THREAD AUTHOR association on a clause that an issue_comment payload also "+
			"reaches -- it carries both `comment` and `issue`", job)
	}
}

// orClauses splits an expression on `||` at parenthesis depth 0 -- the clauses are themselves
// parenthesised -- and drops the empty ones.
func orClauses(expression string) []string {
	var (
		clauses []string
		current strings.Builder
		depth   int
	)
	for index := 0; index < len(expression); index++ {
		character := expression[index]
		switch {
		case character == '(':
			depth++
		case character == ')':
			depth--
		case depth == 0 && strings.HasPrefix(expression[index:], "||"):
			clauses = append(clauses, current.String())
			current.Reset()
			index++
			continue
		}
		current.WriteByte(character)
	}
	clauses = append(clauses, current.String())
	kept := clauses[:0]
	for _, clause := range clauses {
		if clause = strip(clause); clause != "" {
			kept = append(kept, clause)
		}
	}
	return kept
}

// associationsOf reads an allowlist written as a JSON array, sorted the way the comparison wants
// it: by text when every entry is a string, by value when every entry is a number, and as written
// otherwise -- a list mixing the two can never be the privileged one, and has no order to sort by.
func associationsOf(raw string) (*value, error) {
	decoder := json.NewDecoder(strings.NewReader(raw))
	decoder.UseNumber()
	var decoded []any
	if err := decoder.Decode(&decoded); err != nil {
		return nil, err
	}
	if strings.Trim(raw[decoder.InputOffset():], jsonWhitespace) != "" {
		return nil, fmt.Errorf("%s holds more than one JSON value", raw)
	}
	allowed := &value{kind: sequenceKind}
	for _, item := range decoded {
		allowed.items = append(allowed.items, fromJSON(item))
	}
	switch {
	case !slices.ContainsFunc(allowed.items, func(item *value) bool { return !item.is(stringKind) }):
		slices.SortStableFunc(allowed.items, func(left, right *value) int {
			return strings.Compare(left.text, right.text)
		})
	case !slices.ContainsFunc(allowed.items, func(item *value) bool { _, ok := item.numberValue(); return !ok }):
		slices.SortStableFunc(allowed.items, func(left, right *value) int {
			leftNumber, _ := left.numberValue()
			rightNumber, _ := right.numberValue()
			return cmp.Compare(leftNumber, rightNumber)
		})
	}
	return allowed, nil
}

// fromJSON is a decoded JSON value as the value Python's `json.loads` made of it, so a finding
// quotes it the same way: integers stay integers and every other number is a float.
func fromJSON(decoded any) *value {
	switch item := decoded.(type) {
	case nil:
		return newNull()
	case bool:
		return newBool(item)
	case string:
		return newString(item)
	case json.Number:
		if whole, ok := new(big.Int).SetString(item.String(), decimalBase); ok {
			return &value{kind: intKind, integer: whole}
		}
		number, _ := item.Float64()
		return &value{kind: floatKind, number: number}
	case []any:
		list := &value{kind: sequenceKind}
		for _, child := range item {
			list.items = append(list.items, fromJSON(child))
		}
		return list
	case map[string]any:
		return jsonObject(item)
	default:
		return newNull()
	}
}

// jsonObject is a decoded JSON object as a mapping. Go decodes an object into a map, which keeps
// no order, so its keys are put back in text order; a finding only quotes one inside a list that
// is already wrong.
func jsonObject(object map[string]any) *value {
	keys := make([]string, 0, len(object))
	for key := range object {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	mapping := &value{kind: mappingKind}
	for _, key := range keys {
		mapping.pairs = append(mapping.pairs, pair{key: newString(key), value: fromJSON(object[key])})
	}
	return mapping
}

// reprStrings is Python's `repr()` of a list of strings.
func reprStrings(items []string) string {
	list := &value{kind: sequenceKind}
	for _, item := range items {
		list.items = append(list.items, newString(item))
	}
	return list.repr()
}
