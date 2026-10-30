// Package flags is the command line every Terraform helper takes: long
// options only, each `--name value` or `--name=value`, abbreviated to any
// unambiguous prefix, plus `-h`/`--help`.
//
// The helpers' flags are an interface their callers depend on -- the run.sh
// wrappers pass `"$@"` straight through, and consumers' Makefiles and CI
// scripts call them with `--repo-dir`, `--fix`, `--check` -- so the grammar
// and its failures are kept exactly as they were: a misspelt or ambiguous
// option, a missing value, or a value given to a switch is a usage error that
// exits 2 with a `usage:` line, before anything is read or written.
package flags

import (
	"fmt"
	"io"
	"os"
	"regexp"
	"strconv"
	"strings"
)

// ExitUsage is the status a command line that cannot be run exits with.
const ExitUsage = 2

const (
	helpLong  = "--help"
	helpShort = "-h"
	// defaultColumns is the terminal width assumed when none is known.
	defaultColumns = 80
	// widthMargin is how far short of the terminal width lines wrap.
	widthMargin = 2
	// helpColumn is the furthest an option's description starts in `--help`.
	helpColumn = 24
	// helpGutter is how much of a narrow line `--help` keeps for descriptions.
	helpGutter = 20
	// minimumHelpWidth is the narrowest a description is ever wrapped to.
	minimumHelpWidth = 11
	// optionIndent is how far an option is indented in `--help`.
	optionIndent = 2
	// promptFraction is how much of the line a program name may use before
	// the usage text moves to the next line.
	promptFraction = 0.75
)

// negativeNumber is a value that starts with `-` yet is a value, not an option.
var negativeNumber = regexp.MustCompile(`^-\d+$|^-\d*\.\d+$`)

// Option is one long option: a switch, or one that takes a value.
type Option struct {
	Name    string
	Help    string
	Default string
	Value   bool
}

// metavar is how an option's value is named in `usage:`: `--repo-dir` takes
// `REPO_DIR`.
func (o Option) metavar() string {
	return strings.ToUpper(strings.ReplaceAll(strings.TrimLeft(o.Name, "-"), "-", "_"))
}

// usage is the option as `usage:` shows it.
func (o Option) usage() string {
	if o.Value {
		return "[" + o.Name + " " + o.metavar() + "]"
	}
	return "[" + o.Name + "]"
}

// Parser is one helper's command line.
type Parser struct {
	Prog        string
	Description string
	Options     []Option
}

// Values are the parsed command line: every option's value, defaults filled in.
type Values struct {
	strings  map[string]string
	switches map[string]bool
}

// String is the value of an option that takes one.
func (v Values) String(name string) string {
	return v.strings[name]
}

// Bool is whether a switch was given.
func (v Values) Bool(name string) bool {
	return v.switches[name]
}

// match is one argument read as an option: which one, and a value given with
// `=` if there was one. `joined` is a value written straight after `-h`, as in
// `-hx`, which reads as more short options rather than as a value: `-h`
// itself still asks for help.
type match struct {
	option   *Option
	help     bool
	joined   bool
	explicit *string
}

// unknown is an argument that looks like an option no option is.
func (m match) unknown() bool {
	return m.option == nil && !m.help
}

// helpError is why `-h` given a value is an error, or nothing when it is a
// request for help: `-hx` reads as `-h` followed by more short options, while
// `-h=x`, `-h-x` and `--help=x` hand help a value it cannot take.
func (m match) helpError() string {
	if m.explicit == nil || m.joined && !strings.HasPrefix(*m.explicit, "-") {
		return ""
	}
	return "argument -h/--help: ignored explicit argument " + quote(*m.explicit)
}

// apply records the option at `at` in `values`: how many following arguments
// it consumed, or why it cannot be applied.
func (m match) apply(values Values, arguments []string, matches map[int]match, at int) (int, string) {
	option := m.option
	switch {
	case !option.Value && m.explicit != nil:
		return 0, "argument " + option.Name + ": ignored explicit argument " + quote(*m.explicit)
	case !option.Value:
		values.switches[option.Name] = true
		return 0, ""
	case m.explicit != nil:
		values.strings[option.Name] = *m.explicit
		return 0, ""
	}
	next := at + 1
	if _, isOption := matches[next]; next >= len(arguments) || isOption || arguments[next] == "--" {
		return 0, "argument " + option.Name + ": expected one argument"
	}
	values.strings[option.Name] = arguments[next]
	return 1, ""
}

// defaults are the values before any argument is read.
func (p Parser) defaults() Values {
	values := Values{strings: map[string]string{}, switches: map[string]bool{}}
	for _, option := range p.Options {
		if option.Value {
			values.strings[option.Name] = option.Default
		}
	}
	return values
}

// Parse reads `arguments`. It returns the values and true to go on, or an exit
// status and false when the command line was a request for help (0) or could
// not be run (2), the help or the error already written.
func (p Parser) Parse(arguments []string, stdout, stderr io.Writer) (Values, int, bool) {
	values := p.defaults()
	matches, err := p.classify(arguments)
	if err != nil {
		return values, p.fail(stderr, err.Error()), false
	}
	var extras []string
	for at := 0; at < len(arguments); at++ {
		found, isOption := matches[at]
		if !isOption || found.unknown() {
			extras = append(extras, arguments[at])
			continue
		}
		if found.help {
			if message := found.helpError(); message != "" {
				return values, p.fail(stderr, message), false
			}
			p.help(stdout)
			return values, 0, false
		}
		consumed, message := found.apply(values, arguments, matches, at)
		if message != "" {
			return values, p.fail(stderr, message), false
		}
		at += consumed
	}
	if len(extras) > 0 {
		return values, p.fail(stderr, "unrecognized arguments: "+strings.Join(extras, " ")), false
	}
	return values, 0, true
}

// classify reads every argument that looks like an option, before any is
// acted on: an ambiguous abbreviation anywhere is an error even after `-h`.
// Everything after `--` is a value, never an option.
func (p Parser) classify(arguments []string) (map[int]match, error) {
	matches := map[int]match{}
	for i, argument := range arguments {
		if argument == "--" {
			break
		}
		found, isOption, err := p.lookup(argument)
		if err != nil {
			return nil, err
		}
		if isOption {
			matches[i] = found
		}
	}
	return matches, nil
}

// names are every option name, `--help` and `-h` included, in declaration order.
func (p Parser) names() []string {
	names := []string{helpShort, helpLong}
	for _, option := range p.Options {
		names = append(names, option.Name)
	}
	return names
}

// resolve is the option a full name stands for.
func (p Parser) resolve(name string, explicit *string) match {
	if name == helpShort || name == helpLong {
		return match{help: true, explicit: explicit}
	}
	for i := range p.Options {
		if p.Options[i].Name == name {
			return match{option: &p.Options[i], explicit: explicit}
		}
	}
	return match{}
}

// exact is the option `name` is spelt in full, if any.
func (p Parser) exact(name string, explicit *string) (match, bool) {
	for _, known := range p.names() {
		if name == known {
			return p.resolve(known, explicit), true
		}
	}
	return match{}, false
}

// abbreviation is the one option `name` is a prefix of; an error names every
// option it could be when it is a prefix of several.
func (p Parser) abbreviation(argument, name string, explicit *string) (match, bool, error) {
	var candidates []string
	for _, known := range p.names() {
		if strings.HasPrefix(known, name) {
			candidates = append(candidates, known)
		}
	}
	switch len(candidates) {
	case 0:
		return match{}, false, nil
	case 1:
		return p.resolve(candidates[0], explicit), true, nil
	default:
		return match{}, false, fmt.Errorf(
			"ambiguous option: %s could match %s", argument, strings.Join(candidates, ", "),
		)
	}
}

// lookup reads one argument: an option it names or abbreviates, an unknown
// option, or a value. A lone `-`, a negative number and anything holding a
// space are values.
func (p Parser) lookup(argument string) (match, bool, error) {
	if argument == "" || argument[0] != '-' {
		return match{}, false, nil
	}
	if found, ok := p.exact(argument, nil); ok {
		return found, true, nil
	}
	if len(argument) == 1 {
		return match{}, false, nil
	}
	name, value, hasValue := strings.Cut(argument, "=")
	var explicit *string
	if hasValue {
		explicit = &value
		if found, ok := p.exact(name, explicit); ok {
			return found, true, nil
		}
	}
	switch {
	case strings.HasPrefix(argument, "--"):
		if found, ok, err := p.abbreviation(argument, name, explicit); ok || err != nil {
			return found, ok, err
		}
	case strings.HasPrefix(argument, helpShort):
		rest := argument[len(helpShort):]
		return match{help: true, joined: true, explicit: &rest}, true, nil
	}
	if negativeNumber.MatchString(argument) || strings.Contains(argument, " ") {
		return match{}, false, nil
	}
	return match{}, true, nil
}

// quote shows a value the way a usage error names it.
func quote(value string) string {
	if strings.Contains(value, "'") && !strings.Contains(value, `"`) {
		return `"` + value + `"`
	}
	return "'" + strings.ReplaceAll(value, "'", `\'`) + "'"
}

// width is the line length usage text wraps at: the terminal's, as `COLUMNS`
// gives it, short of a margin.
func width() int {
	columns := defaultColumns
	if parsed, err := strconv.Atoi(os.Getenv("COLUMNS")); err == nil && parsed > 0 {
		columns = parsed
	}
	return columns - widthMargin
}

// usage is the `usage:` line, wrapped under the program name when it is long.
func (p Parser) usage() string {
	const prefix = "usage: "
	parts := []string{"[" + helpShort + "]"}
	for _, option := range p.Options {
		parts = append(parts, option.usage())
	}
	single := prefix + p.Prog + " " + strings.Join(parts, " ")
	textWidth := width()
	if len(single) <= textWidth {
		return single + "\n"
	}
	indent := strings.Repeat(" ", len(prefix)+len(p.Prog)+1)
	if float64(len(prefix)+len(p.Prog)) > promptFraction*float64(textWidth) {
		indent = strings.Repeat(" ", len(prefix))
		lines := wrap(parts, indent, textWidth, len(indent)-1)
		return prefix + p.Prog + "\n" + strings.Join(lines, "\n") + "\n"
	}
	lines := wrap(append([]string{p.Prog}, parts...), indent, textWidth, len(prefix)-1)
	lines[0] = strings.TrimPrefix(lines[0], indent)
	return prefix + strings.Join(lines, "\n") + "\n"
}

// wrap packs `parts` into lines no longer than `textWidth`, each indented.
func wrap(parts []string, indent string, textWidth, start int) []string {
	var (
		lines []string
		line  []string
	)
	length := start
	for _, part := range parts {
		if length+1+len(part) > textWidth && len(line) > 0 {
			lines = append(lines, indent+strings.Join(line, " "))
			line = nil
			length = len(indent) - 1
		}
		line = append(line, part)
		length += len(part) + 1
	}
	if len(line) > 0 {
		lines = append(lines, indent+strings.Join(line, " "))
	}
	return lines
}

// fail reports a command line that cannot be run.
func (p Parser) fail(stderr io.Writer, message string) int {
	_, _ = fmt.Fprint(stderr, p.usage())
	_, _ = fmt.Fprintf(stderr, "%s: error: %s\n", p.Prog, message)
	return ExitUsage
}

// help writes `--help`: the usage line, the description, and every option
// with its description in a column, wrapped to the terminal's width.
func (p Parser) help(stdout io.Writer) {
	_, _ = fmt.Fprint(stdout, p.usage())
	if p.Description != "" {
		_, _ = fmt.Fprintf(stdout, "\n%s\n", p.Description)
	}
	invocations := []string{helpShort + ", " + helpLong}
	descriptions := []string{"show this help message and exit"}
	for _, option := range p.Options {
		invocation := option.Name
		if option.Value {
			invocation += " " + option.metavar()
		}
		invocations = append(invocations, invocation)
		descriptions = append(descriptions, option.Help)
	}
	textWidth := width()
	column := optionIndent
	for _, invocation := range invocations {
		column = max(column, len(invocation)+optionIndent+optionIndent)
	}
	column = min(column, min(helpColumn, max(textWidth-helpGutter, optionIndent+optionIndent)))
	_, _ = fmt.Fprint(stdout, "\noptions:\n")
	for i, invocation := range invocations {
		helpLine(stdout, invocation, descriptions[i], column, max(textWidth-column, minimumHelpWidth))
	}
}

// helpLine is one option in `--help`, its description starting at `column`
// and wrapped at `wrapAt` characters.
func helpLine(stdout io.Writer, invocation, description string, column, wrapAt int) {
	lead := strings.Repeat(" ", optionIndent) + invocation
	if description == "" {
		_, _ = fmt.Fprintln(stdout, lead)
		return
	}
	lines := wrapWords(description, wrapAt)
	indent := strings.Repeat(" ", column)
	if len(invocation) <= column-optionIndent-optionIndent {
		_, _ = fmt.Fprintln(stdout, lead+strings.Repeat(" ", column-len(lead))+lines[0])
		lines = lines[1:]
	} else {
		_, _ = fmt.Fprintln(stdout, lead)
	}
	for _, line := range lines {
		_, _ = fmt.Fprintln(stdout, indent+line)
	}
}

// wrapWords fills words into lines no longer than `limit`, breaking a word
// longer than a whole line.
func wrapWords(text string, limit int) []string {
	var (
		lines []string
		line  string
	)
	for word := range strings.FieldsSeq(text) {
		for len(word) > limit {
			if line != "" {
				lines = append(lines, line)
				line = ""
			}
			lines = append(lines, word[:limit])
			word = word[limit:]
		}
		switch {
		case line == "":
			line = word
		case len(line)+1+len(word) <= limit:
			line += " " + word
		default:
			lines = append(lines, line)
			line = word
		}
	}
	if line != "" {
		lines = append(lines, line)
	}
	return lines
}
