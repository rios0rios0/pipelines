package main

import (
	"errors"
	"fmt"
	"math"
	"regexp"
	"strconv"
	"strings"
	"unicode"
	"unicode/utf8"
)

// A strict evaluator for the part of the GitHub Actions expression language a job-level `if:`
// guard is written in: string literals, `true`, `false` and `null`, dotted context properties,
// `!`, `==`, `!=`, `&&`, `||`, parentheses, and the functions `startsWith`, `endsWith`, `contains`
// and `format`. It follows GitHub's rules for that subset: strings compare ignoring case, the
// functions ignore case and cast their arguments to strings, `==` between different types compares
// them as numbers, and only `false`, the empty string and `null` are falsy (the numbers GitHub also
// counts as falsy never arise, since no number is ever a value here).
//
// Anything else -- a number, a comparison, an index, another function, a `${{ }}` wrapper -- is an
// error rather than a guess: a verdict this evaluator cannot be sure of must fail the assertion by
// name, never pass or fail it silently.

// exprKind is the type of an expression value. The guards evaluated here compare strings and
// booleans; numbers exist only as what GitHub coerces those to when `==` compares across types.
type exprKind int

const (
	exprNull exprKind = iota
	exprBool
	exprString
)

// exprValue is the value of an expression.
type exprValue struct {
	kind    exprKind
	boolean bool
	text    string
}

func exprText(text string) exprValue { return exprValue{kind: exprString, text: text} }

func exprBoolean(boolean bool) exprValue { return exprValue{kind: exprBool, boolean: boolean} }

// truthy is GitHub's truth value: null, false and the empty string are false.
func (v exprValue) truthy() bool {
	switch v.kind {
	case exprNull:
		return false
	case exprBool:
		return v.boolean
	case exprString:
		return v.text != ""
	default:
		return false
	}
}

// cast is GitHub's conversion of a value to a string, which every function here applies to its
// arguments: null is empty and a boolean is `true` or `false`.
func (v exprValue) cast() string {
	switch v.kind {
	case exprNull:
		return ""
	case exprBool:
		return strconv.FormatBool(v.boolean)
	case exprString:
		return v.text
	default:
		return ""
	}
}

var (
	// jsonNumberText is the JSON number grammar, the only text GitHub reads as a number.
	jsonNumberText = regexp.MustCompile(`^-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][-+]?[0-9]+)?$`)
	// formatIndex is what may sit between the braces of a `format` placeholder.
	formatIndex = regexp.MustCompile(`^[0-9]+$`)
)

// number is GitHub's conversion of a value to a number for `==` across types: null and false are
// 0, true is 1, the empty string is 0, a string spelling a JSON number is that number, and any
// other string is NaN, which equals nothing.
func (v exprValue) number() float64 {
	switch v.kind {
	case exprNull:
		return 0
	case exprBool:
		if v.boolean {
			return 1
		}
		return 0
	case exprString:
		if v.text == "" {
			return 0
		}
		if !jsonNumberText.MatchString(v.text) {
			return math.NaN()
		}
		number, _ := strconv.ParseFloat(v.text, 64)
		return number
	default:
		return math.NaN()
	}
}

// equal is GitHub's `==`: values of one type compare directly, strings ignoring case, and values of
// different types compare as numbers.
func equal(left, right exprValue) bool {
	if left.kind == right.kind {
		switch left.kind {
		case exprNull:
			return true
		case exprBool:
			return left.boolean == right.boolean
		case exprString:
			return strings.EqualFold(left.text, right.text)
		}
	}
	return left.number() == right.number()
}

// lookup resolves a context property such as `github.event.pull_request.draft`. It fails for a
// property the caller did not provide, so a guard that reads something the test does not model is
// reported rather than evaluated as if it were empty.
type lookup func(path string) (exprValue, error)

// node is a parsed expression.
type node interface {
	evaluate(read lookup) (exprValue, error)
}

type literalNode struct{ value exprValue }

func (n literalNode) evaluate(lookup) (exprValue, error) { return n.value, nil }

type propertyNode struct{ path string }

func (n propertyNode) evaluate(read lookup) (exprValue, error) { return read(n.path) }

type notNode struct{ operand node }

func (n notNode) evaluate(read lookup) (exprValue, error) {
	operand, err := n.operand.evaluate(read)
	if err != nil {
		return exprValue{}, err
	}
	return exprBoolean(!operand.truthy()), nil
}

// logicalNode is `&&` or `||`. Like GitHub, it returns an operand rather than a boolean and
// evaluates the right one only when the left does not decide.
type logicalNode struct {
	and         bool
	left, right node
}

func (n logicalNode) evaluate(read lookup) (exprValue, error) {
	left, err := n.left.evaluate(read)
	if err != nil {
		return exprValue{}, err
	}
	if left.truthy() != n.and {
		return left, nil
	}
	return n.right.evaluate(read)
}

type comparisonNode struct {
	negated     bool
	left, right node
}

func (n comparisonNode) evaluate(read lookup) (exprValue, error) {
	left, err := n.left.evaluate(read)
	if err != nil {
		return exprValue{}, err
	}
	right, err := n.right.evaluate(read)
	if err != nil {
		return exprValue{}, err
	}
	return exprBoolean(equal(left, right) != n.negated), nil
}

type callNode struct {
	function  function
	arguments []node
}

func (n callNode) evaluate(read lookup) (exprValue, error) {
	arguments := make([]exprValue, 0, len(n.arguments))
	for _, argument := range n.arguments {
		evaluated, err := argument.evaluate(read)
		if err != nil {
			return exprValue{}, err
		}
		arguments = append(arguments, evaluated)
	}
	return n.function.call(arguments)
}

// function is one of the functions the evaluator models.
type function struct {
	name     string
	minimum  int
	variadic bool
	call     func(arguments []exprValue) (exprValue, error)
}

// functions maps each modelled function, by its lower-case name, to its definition: GitHub
// matches function names ignoring case.
func functions() map[string]function {
	return map[string]function{
		"startswith": {
			name:    "startsWith",
			minimum: binaryArguments,
			call: func(arguments []exprValue) (exprValue, error) {
				return exprBoolean(hasPrefixFold(arguments[0].cast(), arguments[1].cast())), nil
			},
		},
		"endswith": {name: "endsWith", minimum: binaryArguments, call: func(arguments []exprValue) (exprValue, error) {
			return exprBoolean(hasSuffixFold(arguments[0].cast(), arguments[1].cast())), nil
		}},
		"contains": {name: "contains", minimum: binaryArguments, call: func(arguments []exprValue) (exprValue, error) {
			return exprBoolean(containsFold(arguments[0].cast(), arguments[1].cast())), nil
		}},
		"format": {name: "format", minimum: 1, variadic: true, call: format},
	}
}

// format is GitHub's `format(template, replace0, replace1, ...)`: `{N}` is the Nth replacement,
// `{{` and `}}` are literal braces, and any other brace is an error.
func format(arguments []exprValue) (exprValue, error) {
	template := arguments[0].cast()
	var out strings.Builder
	for index := 0; index < len(template); index++ {
		character := template[index]
		switch {
		case character == '{' && strings.HasPrefix(template[index+1:], "{"),
			character == '}' && strings.HasPrefix(template[index+1:], "}"):
			out.WriteByte(character)
			index++
		case character == '{':
			closing := strings.IndexByte(template[index:], '}')
			if closing < 0 {
				return exprValue{}, fmt.Errorf("format string %q has an unclosed {", template)
			}
			digits := template[index+1 : index+closing]
			position, err := strconv.Atoi(digits)
			if !formatIndex.MatchString(digits) || err != nil || position+1 >= len(arguments) {
				return exprValue{}, fmt.Errorf("format string %q names no argument at %q",
					template, template[index:index+closing+1])
			}
			out.WriteString(arguments[position+1].cast())
			index += closing
		case character == '}':
			return exprValue{}, fmt.Errorf("format string %q has an unopened }", template)
		default:
			out.WriteByte(character)
		}
	}
	return exprText(out.String()), nil
}

// hasPrefixFold is `strings.HasPrefix` ignoring case.
func hasPrefixFold(text, prefix string) bool {
	_, ok := prefixFold(text, 0, prefix)
	return ok
}

// hasSuffixFold is `strings.HasSuffix` ignoring case.
func hasSuffixFold(text, suffix string) bool {
	for suffix != "" {
		want, wantSize := utf8.DecodeLastRuneInString(suffix)
		got, gotSize := utf8.DecodeLastRuneInString(text)
		if text == "" || !strings.EqualFold(string(got), string(want)) {
			return false
		}
		suffix, text = suffix[:len(suffix)-wantSize], text[:len(text)-gotSize]
	}
	return true
}

// containsFold is `strings.Contains` ignoring case.
func containsFold(text, part string) bool {
	for start := 0; ; {
		if _, ok := prefixFold(text, start, part); ok {
			return true
		}
		if start >= len(text) {
			return false
		}
		_, size := utf8.DecodeRuneInString(text[start:])
		start += size
	}
}

// binaryArguments is how many arguments `startsWith`, `endsWith` and `contains` take.
const binaryArguments = 2

// tokenKind is the kind of a lexical token.
type tokenKind int

const (
	tokenEnd tokenKind = iota
	tokenString
	tokenName
	tokenDot
	tokenComma
	tokenOpen
	tokenClose
	tokenNot
	tokenEqual
	tokenNotEqual
	tokenAnd
	tokenOr
)

type token struct {
	kind   tokenKind
	text   string
	offset int
}

// operators maps each operator and punctuation mark to its token, longest spelling first where
// one is a prefix of another.
func operators() []token {
	return []token{
		{kind: tokenNotEqual, text: "!="},
		{kind: tokenEqual, text: "=="},
		{kind: tokenAnd, text: "&&"},
		{kind: tokenOr, text: "||"},
		{kind: tokenNot, text: "!"},
		{kind: tokenDot, text: "."},
		{kind: tokenComma, text: ","},
		{kind: tokenOpen, text: "("},
		{kind: tokenClose, text: ")"},
	}
}

var nameToken = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_-]*`)

// errUnterminatedString is a string literal with no closing quote.
var errUnterminatedString = errors.New("a string literal is never closed")

// tokenize splits an expression into tokens, refusing any character the subset does not use.
func tokenize(expression string) ([]token, error) {
	var tokens []token
	for offset := 0; offset < len(expression); {
		character, size := utf8.DecodeRuneInString(expression[offset:])
		switch {
		case unicode.IsSpace(character):
			offset += size
		case character == '\'':
			text, length, err := stringLiteral(expression[offset:])
			if err != nil {
				return nil, fmt.Errorf("at offset %d: %w", offset, err)
			}
			tokens = append(tokens, token{kind: tokenString, text: text, offset: offset})
			offset += length
		default:
			next, err := plainToken(expression, offset)
			if err != nil {
				return nil, err
			}
			tokens = append(tokens, next)
			offset += len(next.text)
		}
	}
	return append(tokens, token{kind: tokenEnd, offset: len(expression)}), nil
}

// plainToken is the name, operator or punctuation mark at `offset`.
func plainToken(expression string, offset int) (token, error) {
	if name := nameToken.FindString(expression[offset:]); name != "" {
		return token{kind: tokenName, text: name, offset: offset}, nil
	}
	for _, operator := range operators() {
		if strings.HasPrefix(expression[offset:], operator.text) {
			operator.offset = offset
			return operator, nil
		}
	}
	character, _ := utf8.DecodeRuneInString(expression[offset:])
	return token{}, fmt.Errorf("at offset %d: %q is not part of the expression subset this test evaluates",
		offset, character)
}

// stringLiteral reads the single-quoted literal `source` starts with, where a doubled quote is one, and
// returns its text and how many bytes it took.
func stringLiteral(source string) (string, int, error) {
	var text strings.Builder
	for index := 1; index < len(source); index++ {
		if source[index] != '\'' {
			text.WriteByte(source[index])
			continue
		}
		if strings.HasPrefix(source[index+1:], "'") {
			text.WriteByte('\'')
			index++
			continue
		}
		return text.String(), index + 1, nil
	}
	return "", 0, errUnterminatedString
}

// parseExpression parses an `if:` condition. Precedence follows GitHub's: `!` binds tightest, then
// `==` and `!=`, then `&&`, then `||`.
func parseExpression(expression string) (node, error) {
	tokens, err := tokenize(expression)
	if err != nil {
		return nil, err
	}
	p := parser{tokens: tokens, functions: functions()}
	parsed, err := p.or()
	if err != nil {
		return nil, err
	}
	if next := p.peek(); next.kind != tokenEnd {
		return nil, fmt.Errorf("at offset %d: unexpected %q", next.offset, next.text)
	}
	return parsed, nil
}

// evaluateCondition parses `expression` and reports whether it is truthy for the given properties.
func evaluateCondition(expression string, read lookup) (bool, error) {
	parsed, err := parseExpression(expression)
	if err != nil {
		return false, err
	}
	result, err := parsed.evaluate(read)
	if err != nil {
		return false, err
	}
	return result.truthy(), nil
}

type parser struct {
	tokens    []token
	position  int
	functions map[string]function
}

func (p *parser) peek() token { return p.tokens[p.position] }

func (p *parser) next() token {
	current := p.tokens[p.position]
	if current.kind != tokenEnd {
		p.position++
	}
	return current
}

func (p *parser) or() (node, error) {
	left, err := p.and()
	for err == nil && p.peek().kind == tokenOr {
		p.next()
		var right node
		if right, err = p.and(); err == nil {
			left = logicalNode{and: false, left: left, right: right}
		}
	}
	return left, err
}

func (p *parser) and() (node, error) {
	left, err := p.comparison()
	for err == nil && p.peek().kind == tokenAnd {
		p.next()
		var right node
		if right, err = p.comparison(); err == nil {
			left = logicalNode{and: true, left: left, right: right}
		}
	}
	return left, err
}

func (p *parser) comparison() (node, error) {
	left, err := p.unary()
	for err == nil && (p.peek().kind == tokenEqual || p.peek().kind == tokenNotEqual) {
		negated := p.next().kind == tokenNotEqual
		var right node
		if right, err = p.unary(); err == nil {
			left = comparisonNode{negated: negated, left: left, right: right}
		}
	}
	return left, err
}

func (p *parser) unary() (node, error) {
	if p.peek().kind == tokenNot {
		p.next()
		operand, err := p.unary()
		if err != nil {
			return nil, err
		}
		return notNode{operand: operand}, nil
	}
	return p.primary()
}

func (p *parser) primary() (node, error) {
	current := p.next()
	if current.kind == tokenString {
		return literalNode{value: exprText(current.text)}, nil
	}
	if current.kind == tokenName {
		return p.name(current)
	}
	if current.kind != tokenOpen {
		return nil, fmt.Errorf("at offset %d: expected a value, found %q", current.offset, current.text)
	}
	inner, err := p.or()
	if err != nil {
		return nil, err
	}
	if closing := p.next(); closing.kind != tokenClose {
		return nil, fmt.Errorf("at offset %d: expected ) to close the ( at offset %d", closing.offset, current.offset)
	}
	return inner, nil
}

// name parses what a name starts: a function call, a context property, or a keyword literal.
func (p *parser) name(current token) (node, error) {
	if p.peek().kind == tokenOpen {
		return p.call(current)
	}
	if p.peek().kind == tokenDot {
		path := current.text
		for p.peek().kind == tokenDot {
			p.next()
			segment := p.next()
			if segment.kind != tokenName {
				return nil, fmt.Errorf("at offset %d: expected a property name after %q", segment.offset, path+".")
			}
			path += "." + segment.text
		}
		return propertyNode{path: path}, nil
	}
	if literal, ok := keywords()[current.text]; ok {
		return literalNode{value: literal}, nil
	}
	return nil, fmt.Errorf("at offset %d: %q is neither a literal, a context property nor a function call",
		current.offset, current.text)
}

// keywords are the literal names, spelled in lower case as GitHub spells them.
func keywords() map[string]exprValue {
	return map[string]exprValue{
		"true":   exprBoolean(true),
		"false":  exprBoolean(false),
		nullName: {kind: exprNull},
	}
}

func (p *parser) call(name token) (node, error) {
	definition, ok := p.functions[strings.ToLower(name.text)]
	if !ok {
		return nil, fmt.Errorf("at offset %d: %s() is not a function this test evaluates", name.offset, name.text)
	}
	p.next() // (
	var arguments []node
	for p.peek().kind != tokenClose {
		if len(arguments) > 0 {
			if separator := p.next(); separator.kind != tokenComma {
				return nil, fmt.Errorf(
					"at offset %d: expected , or ) in the arguments of %s()",
					separator.offset,
					name.text,
				)
			}
		}
		argument, err := p.or()
		if err != nil {
			return nil, err
		}
		arguments = append(arguments, argument)
	}
	p.next() // )
	if len(arguments) < definition.minimum || (!definition.variadic && len(arguments) > definition.minimum) {
		return nil, fmt.Errorf("at offset %d: %s() takes %d arguments, not %d",
			name.offset, definition.name, definition.minimum, len(arguments))
	}
	return callNode{function: definition, arguments: arguments}, nil
}
