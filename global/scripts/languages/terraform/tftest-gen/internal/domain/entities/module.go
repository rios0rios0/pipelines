// Package entities holds what the smoke-test generator reads out of a module
// -- its variables and the providers it requires -- and the test file it
// writes for them.
package entities

import (
	"regexp"
	"strings"
	"unicode/utf8"

	"github.com/rios0rios0/pipelines/global/scripts/languages/terraform/internal/text"
)

const space = text.Space

var (
	variableBlock = regexp.MustCompile(
		`(?ms)^` + space + `*variable` + space + `+"([^"]+)"` + space + `*\{(.*?)^\}` + space + `*$`,
	)
	defaultAttribute  = regexp.MustCompile(`(?m)^` + space + `*default` + space + `*=` + space + `*`)
	validationBlock   = regexp.MustCompile(`(?s)validation` + space + `*\{`)
	requiredProviders = regexp.MustCompile(`required_providers` + space + `*\{`)
	providerEntry     = regexp.MustCompile(`(?s)([A-Za-z_][A-Za-z0-9_-]*)` + space + `*=` + space + `*\{([^}]*)\}`)
	providerSource    = regexp.MustCompile(`source` + space + `*=` + space + `*"([^"]+)"`)
)

// Variable is one `variable` block of `variables.tf`.
type Variable struct {
	Name       string
	Type       string
	Required   bool
	Validation bool
}

// Provider is one `required_providers` entry: its local name and source.
type Provider struct {
	Local  string
	Source string
}

// ParseVariables reads every `variable "<name>" { ... }` block whose closing
// brace sits at column 0. A block with no `type` is a string; one with a
// `default` is optional; one with a `validation` block has a guard to test.
func ParseVariables(source string) []Variable {
	var variables []Variable
	for _, match := range variableBlock.FindAllStringSubmatch(source, -1) {
		body := match[2]
		typeExpression, found := AttributeExpression(body, "type")
		if !found || typeExpression == "" {
			typeExpression = typeString
		}
		variables = append(variables, Variable{
			Name:       match[1],
			Type:       text.Strip(typeExpression),
			Required:   !defaultAttribute.MatchString(body),
			Validation: validationBlock.MatchString(body),
		})
	}
	return variables
}

// AttributeExpression is the value of the first `name = ...` line of `body`,
// stripped, read up to where the expression ends.
func AttributeExpression(body, name string) (string, bool) {
	pattern := regexp.MustCompile(`(?m)^` + space + `*` + regexp.QuoteMeta(name) + space + `*=` + space + `*`)
	location := pattern.FindStringIndex(body)
	if location == nil {
		return "", false
	}
	return text.Strip(balancedExpression(body, location[1])), true
}

// balancedExpression is the expression starting at `start`: up to a newline
// or a closing bracket outside any bracket it opened, strings skipped. A
// second `=` on the line cuts it one character before the name that `=`
// assigns, so `string description = "x"` reads `strin`. That quirk is kept as
// it has always been: the stub, and so the committed test, of every module
// declaring a variable on one line depends on it.
func balancedExpression(source string, start int) string {
	depth := 0
	inString, quote := false, byte(0)
	at := start
	for at < len(source) {
		current := source[at]
		if inString {
			if current == '\\' {
				at += 2
				continue
			}
			if current == quote {
				inString = false
			}
			at++
			continue
		}
		switch {
		case current == '"' || current == '\'':
			inString, quote = true, current
		case strings.IndexByte("([{", current) >= 0:
			depth++
		case strings.IndexByte(")]}", current) >= 0:
			if depth == 0 {
				return source[start:at]
			}
			depth--
		case current == '\n' && depth == 0:
			return source[start:at]
		case current == '=' && depth == 0 && at > start:
			return text.RStrip(source[start:assignedNameStart(source, start, at)])
		}
		at++
	}
	return source[start:min(at, len(source))]
}

// assignedNameStart walks back from the `=` at `at` over blanks, the name it
// assigns and the blanks before that, never past `start`, a character at a
// time.
func assignedNameStart(source string, start, at int) int {
	back := func(position int, keep func(byte) bool) int {
		for position > start && keep(source[position]) {
			_, width := utf8.DecodeLastRuneInString(source[:position])
			position -= width
		}
		return position
	}
	_, width := utf8.DecodeLastRuneInString(source[:at])
	position := back(at-width, isBlank)
	position = back(position, isNameByte)
	return back(position, isBlank)
}

func isBlank(b byte) bool {
	return b == ' ' || b == '\t'
}

func isNameByte(b byte) bool {
	return b >= 'a' && b <= 'z' || b >= 'A' && b <= 'Z' || b >= '0' && b <= '9' || b == '_'
}

// ParseRequiredProviders reads the entries of the first `required_providers`
// block, each `local = { ... source = "..." ... }`; an entry with no source
// is `unknown`.
func ParseRequiredProviders(source string) []Provider {
	location := requiredProviders.FindStringIndex(source)
	if location == nil {
		return nil
	}
	start := location[1]
	end := closingBrace(source, start)
	var providers []Provider
	for _, match := range providerEntry.FindAllStringSubmatch(source[start:end], -1) {
		origin := "unknown"
		if found := providerSource.FindStringSubmatch(match[2]); found != nil {
			origin = found[1]
		}
		providers = append(providers, Provider{Local: match[1], Source: origin})
	}
	return providers
}

// closingBrace is where the block opened just before `start` closes, strings
// skipped; the end of `source` when it never does.
func closingBrace(source string, start int) int {
	depth := 1
	inString, quote := false, byte(0)
	at := start
	for at < len(source) && depth > 0 {
		current := source[at]
		if inString {
			if current == '\\' {
				at += 2
				continue
			}
			if current == quote {
				inString = false
			}
			at++
			continue
		}
		switch current {
		case '"', '\'':
			inString, quote = true, current
		case '{':
			depth++
		case '}':
			depth--
			if depth == 0 {
				return at
			}
		}
		at++
	}
	return min(at, len(source))
}
