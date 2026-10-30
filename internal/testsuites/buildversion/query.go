package main

import (
	"errors"
	"fmt"
	"strconv"
	"strings"

	"github.com/rios0rios0/pipelines/internal/testsuites/yamldoc"
)

// An expression is the suite's question about one file. It may say:
//
//	doc                        the parsed file
//	trigger                    its `on:` block
//	value['key']               a mapping's entry, or a list's item at an integer index
//	step(steps, 'fragment')    the first step whose `id` equals, or whose `uses` contains, the fragment
//	id_index(steps, 'id')      the position of the first step whose `id` is the text
//	uses_index(steps, 'part')  the position of the first step whose `uses` contains the text
//	'text' in value            whether a string contains the text, or a list or mapping holds it
//	position < position        and `>`: how two positions compare
//
// The answer is printed the way the suite has always compared it: a string as
// itself, a null as nothing, a boolean as `True` or `False`.

// queryError is a failed query, named the way the suite's messages name one.
type queryError struct {
	kind    string
	message string
}

func (e *queryError) Error() string {
	return "<" + e.kind + ": " + e.message + ">"
}

func fail(kind, format string, arguments ...any) error {
	return &queryError{kind: kind, message: fmt.Sprintf(format, arguments...)}
}

// answer evaluates `expression` over the YAML file at `path` and renders the result.
func answer(path, expression string) string {
	document, err := yamldoc.Load(path, yamldoc.Options{})
	if err != nil {
		return (&queryError{kind: "YAMLError", message: err.Error()}).Error()
	}
	parsed, err := parse(expression)
	if err == nil {
		var result value
		if result, err = parsed.evaluate(document); err == nil {
			return result.render()
		}
	}
	var failed *queryError
	if errors.As(err, &failed) {
		return failed.Error()
	}
	return (&queryError{kind: "Error", message: err.Error()}).Error()
}

// valueKind is what an intermediate result holds.
type valueKind int

const (
	nodeValue valueKind = iota
	textValue
	numberValue
	truthValue
)

// value is an intermediate result: a part of the document, or a literal, a
// position or a truth the expression computed.
type value struct {
	kind   valueKind
	node   *yamldoc.Node
	text   string
	number int
	truth  bool
}

func (v value) render() string {
	switch v.kind {
	case textValue:
		return v.text
	case numberValue:
		return strconv.Itoa(v.number)
	case truthValue:
		if v.truth {
			return "True"
		}
		return "False"
	case nodeValue:
	}
	if v.node.Kind() == yamldoc.Null {
		return ""
	}
	return v.node.Str()
}

// typeName is the name of a value's type, as the suite's messages spell it.
func (v value) typeName() string {
	switch v.kind {
	case textValue:
		return "str"
	case numberValue:
		return "int"
	case truthValue:
		return "bool"
	case nodeValue:
	}
	return map[yamldoc.Kind]string{
		yamldoc.Null: "NoneType", yamldoc.Bool: "bool", yamldoc.Int: "int", yamldoc.Float: "float",
		yamldoc.String: "str", yamldoc.Mapping: "dict", yamldoc.Sequence: "list",
	}[v.node.Kind()]
}

// expression is a parsed query.
type expression interface {
	evaluate(document *yamldoc.Node) (value, error)
}

// literal is a quoted string or an integer.
type literal struct{ value value }

func (l literal) evaluate(*yamldoc.Node) (value, error) {
	return l.value, nil
}

// name is `doc` or `trigger`.
type name struct{ identifier string }

func (n name) evaluate(document *yamldoc.Node) (value, error) {
	switch n.identifier {
	case "doc":
		return value{kind: nodeValue, node: document}, nil
	case "trigger":
		return value{kind: nodeValue, node: document.Get("on")}, nil
	}
	return value{}, fail("NameError", "name %s is not defined", yamldoc.Quote(n.identifier))
}

// subscript is `value['key']` or `value[index]`.
type subscript struct {
	target expression
	key    literal
}

func (s subscript) evaluate(document *yamldoc.Node) (value, error) {
	target, err := s.target.evaluate(document)
	if err != nil {
		return value{}, err
	}
	if target.kind != nodeValue {
		return value{}, fail("TypeError", "%s object is not subscriptable", yamldoc.Quote(target.typeName()))
	}
	switch target.node.Kind() {
	case yamldoc.Mapping:
		if s.key.value.kind != textValue || !target.node.Has(s.key.value.text) {
			return value{}, fail("KeyError", "%s", s.key.value.repr())
		}
		return value{kind: nodeValue, node: target.node.Get(s.key.value.text)}, nil
	case yamldoc.Sequence:
		return index(target.node.Items(), s.key.value)
	case yamldoc.String:
		return character(target.node.Text(), s.key.value)
	case yamldoc.Null, yamldoc.Bool, yamldoc.Int, yamldoc.Float:
	}
	return value{}, fail("TypeError", "%s object is not subscriptable", yamldoc.Quote(target.typeName()))
}

// character is the one-character text at an integer index of a string.
func character(text string, key value) (value, error) {
	if key.kind != numberValue {
		return value{}, fail("TypeError", "string indices must be integers, not %s", yamldoc.Quote(key.typeName()))
	}
	characters := []rune(text)
	position := key.number
	if position < 0 {
		position += len(characters)
	}
	if position < 0 || position >= len(characters) {
		return value{}, fail("IndexError", "string index out of range")
	}
	return value{kind: textValue, text: string(characters[position])}, nil
}

func index(items []*yamldoc.Node, key value) (value, error) {
	if key.kind != numberValue {
		return value{}, fail("TypeError", "list indices must be integers or slices, not %s", key.typeName())
	}
	position := key.number
	if position < 0 {
		position += len(items)
	}
	if position < 0 || position >= len(items) {
		return value{}, fail("IndexError", "list index out of range")
	}
	return value{kind: nodeValue, node: items[position]}, nil
}

func (v value) repr() string {
	if v.kind == textValue {
		return yamldoc.Quote(v.text)
	}
	return v.render()
}

// call is one of the three step functions.
type call struct {
	function string
	steps    expression
	argument literal
}

func (c call) evaluate(document *yamldoc.Node) (value, error) {
	steps, err := c.steps.evaluate(document)
	if err != nil {
		return value{}, err
	}
	if steps.kind != nodeValue || c.argument.value.kind != textValue {
		return value{}, fail("TypeError", "%s() takes steps and a text", c.function)
	}
	items, err := stepItems(steps.node, c.function != functionStep)
	if err != nil {
		return value{}, err
	}
	text := c.argument.value.text
	for position, candidate := range items {
		if candidate.Kind() != yamldoc.Mapping {
			return value{}, fail(
				"AttributeError",
				"%s object has no attribute 'get'",
				yamldoc.Quote(kindName(candidate)),
			)
		}
		if c.matches(candidate, text) {
			if c.function == functionStep {
				return value{kind: nodeValue, node: candidate}, nil
			}
			return value{kind: numberValue, number: position}, nil
		}
	}
	switch c.function {
	case functionStep:
		return value{}, fail("LookupError", "no step matches %s", yamldoc.Quote(text))
	case functionIDIndex:
		return value{}, fail("ValueError", "%s is not in list", yamldoc.Quote(text))
	}
	return value{}, fail("IndexError", "list index out of range")
}

func (c call) matches(candidate *yamldoc.Node, text string) bool {
	switch c.function {
	case functionIDIndex:
		return candidate.Get("id").Is(text)
	case functionUsesIndex:
		return strings.Contains(candidate.Get("uses").Str(), text)
	}
	return candidate.Get("id").Is(text) || strings.Contains(candidate.Get("uses").StrOr(""), text)
}

// stepItems are the steps of a list; an unset value holds none. `eager`
// refuses a list holding anything but steps before looking at any of them, as
// listing every step's `id` first does; otherwise only a step reached before a
// match is refused.
func stepItems(steps *yamldoc.Node, eager bool) ([]*yamldoc.Node, error) {
	if !steps.Truthy() {
		return nil, nil
	}
	if steps.Kind() != yamldoc.Sequence {
		return nil, fail("TypeError", "the steps are a %s, not a list", yamldoc.Quote(kindName(steps)))
	}
	for _, item := range steps.Items() {
		if eager && item.Kind() != yamldoc.Mapping {
			return nil, fail("AttributeError", "%s object has no attribute 'get'", yamldoc.Quote(kindName(item)))
		}
	}
	return steps.Items(), nil
}

// kindName is the name of a document value's type.
func kindName(node *yamldoc.Node) string {
	return value{kind: nodeValue, node: node}.typeName()
}

// membership is `'text' in value`.
type membership struct {
	needle   expression
	haystack expression
}

func (m membership) evaluate(document *yamldoc.Node) (value, error) {
	needle, err := m.needle.evaluate(document)
	if err != nil {
		return value{}, err
	}
	haystack, err := m.haystack.evaluate(document)
	if err != nil {
		return value{}, err
	}
	if needle.kind != textValue {
		return value{}, fail("TypeError", "only text can be looked for, not %s", needle.typeName())
	}
	found := false
	switch {
	case haystack.kind == textValue:
		found = strings.Contains(haystack.text, needle.text)
	case haystack.kind != nodeValue:
		return value{}, fail("TypeError", "argument of type %s is not iterable", yamldoc.Quote(haystack.typeName()))
	case haystack.node.IsString():
		found = strings.Contains(haystack.node.Text(), needle.text)
	case haystack.node.Kind() == yamldoc.Mapping:
		found = haystack.node.Has(needle.text)
	case haystack.node.Kind() == yamldoc.Sequence:
		for _, item := range haystack.node.Items() {
			found = found || item.Is(needle.text)
		}
	default:
		return value{}, fail("TypeError", "argument of type %s is not iterable", yamldoc.Quote(haystack.typeName()))
	}
	return value{kind: truthValue, truth: found}, nil
}

// comparison is `position < position` or `position > position`.
type comparison struct {
	left, right expression
	operator    string
}

func (c comparison) evaluate(document *yamldoc.Node) (value, error) {
	left, err := c.left.evaluate(document)
	if err != nil {
		return value{}, err
	}
	right, err := c.right.evaluate(document)
	if err != nil {
		return value{}, err
	}
	if left.kind != numberValue || right.kind != numberValue {
		return value{}, fail("TypeError", "%s not supported between instances of %s and %s",
			yamldoc.Quote(c.operator), yamldoc.Quote(left.typeName()), yamldoc.Quote(right.typeName()))
	}
	if c.operator == "<" {
		return value{kind: truthValue, truth: left.number < right.number}, nil
	}
	return value{kind: truthValue, truth: left.number > right.number}, nil
}
