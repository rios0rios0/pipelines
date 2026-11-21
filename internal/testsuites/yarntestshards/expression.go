package main

import (
	"errors"
	"fmt"
	"math"
	"regexp"
	"strconv"
	"strings"
)

// A strict evaluator for the part of the GitHub Actions expression language the `if:` conditions of
// the sharded tests stage are written in: string, number, boolean and null literals, dotted context
// properties (a segment may hold `-`, as a job id does), `!`, `<`, `<=`, `>`, `>=`, `==`, `!=`, `&&`,
// `||`, parentheses, the four status functions, and `startsWith`, `endsWith`, `contains` and
// `hashFiles`. It follows GitHub's rules for them: strings compare ignoring case, values of two
// types compare as numbers, a comparison with NaN is false, `&&` and `||` return an operand, and a
// condition that calls no status function is read as `success() && (...)`.
//
// Anything else -- an index, a wildcard, another function, a property no scenario models -- is an
// error rather than a guess, so a verdict this evaluator cannot be sure of fails its assertion by
// name instead of passing it.

// kind is the type of an expression value.
type kind int

const (
	nullKind kind = iota
	boolKind
	numberKind
	stringKind
)

// value is the value of an expression.
type value struct {
	kind    kind
	boolean bool
	number  float64
	text    string
}

func booleanValue(boolean bool) value { return value{kind: boolKind, boolean: boolean} }

func numberValue(number float64) value { return value{kind: numberKind, number: number} }

func textValue(text string) value { return value{kind: stringKind, text: text} }

// jsonNumber is the JSON number grammar, which is the text GitHub reads as a number.
var jsonNumber = regexp.MustCompile(`^-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][-+]?[0-9]+)?$`)

// truthy is GitHub's truth value: null, false, 0, NaN and the empty string are false.
func (v value) truthy() bool {
	switch v.kind {
	case nullKind:
		return false
	case boolKind:
		return v.boolean
	case numberKind:
		return v.number != 0 && !math.IsNaN(v.number)
	case stringKind:
		return v.text != ""
	}
	return false
}

// toNumber is GitHub's conversion to a number for a comparison across types: null and false are 0,
// true is 1, the empty string is 0, a string spelling a JSON number is that number, and any other
// string is NaN.
func (v value) toNumber() float64 {
	switch v.kind {
	case nullKind:
		return 0
	case boolKind:
		if v.boolean {
			return 1
		}
		return 0
	case numberKind:
		return v.number
	case stringKind:
		if v.text == "" {
			return 0
		}
		if !jsonNumber.MatchString(v.text) {
			return math.NaN()
		}
		number, err := strconv.ParseFloat(v.text, 64)
		if err != nil {
			return math.NaN()
		}
		return number
	}
	return math.NaN()
}

// cast is GitHub's conversion to a string, which the string functions apply to their arguments.
func (v value) cast() string {
	switch v.kind {
	case nullKind:
		return ""
	case boolKind:
		return strconv.FormatBool(v.boolean)
	case numberKind:
		return strconv.FormatFloat(v.number, 'f', -1, 64)
	case stringKind:
		return v.text
	}
	return ""
}

// equal is GitHub's `==`: values of one type compare directly, strings ignoring case, and values of
// two types compare as numbers, NaN equalling nothing.
func equal(left, right value) bool {
	if left.kind == right.kind {
		switch left.kind {
		case nullKind:
			return true
		case boolKind:
			return left.boolean == right.boolean
		case numberKind:
			return left.number == right.number
		case stringKind:
			return strings.EqualFold(left.text, right.text)
		}
	}
	return left.toNumber() == right.toNumber()
}

// order is GitHub's ordering for `<` and its siblings: two strings compare ignoring case, anything
// else as numbers. It reports false when NaN leaves the two unordered.
func order(left, right value) (int, bool) {
	if left.kind == stringKind && right.kind == stringKind {
		return strings.Compare(strings.ToUpper(left.text), strings.ToUpper(right.text)), true
	}
	first, second := left.toNumber(), right.toNumber()
	if math.IsNaN(first) || math.IsNaN(second) {
		return 0, false
	}
	switch {
	case first < second:
		return -1, true
	case first > second:
		return 1, true
	}
	return 0, true
}

// scenario is what a condition reads: the context properties it is evaluated with, and the outcome
// of what ran before it, as the status functions report it.
type scenario struct {
	properties map[string]value
	failed     bool // a job this one needs, or a step before this one, failed
	cancelled  bool // the run was cancelled
	files      bool // `hashFiles()` finds what it is asked about
}

// property is a context property the scenario models. Every `env.` path resolves to a path, since
// the conditions here only hand those to `hashFiles()`.
func (s *scenario) property(path string) (value, error) {
	if found, ok := s.properties[path]; ok {
		return found, nil
	}
	if strings.HasPrefix(path, "env.") {
		return textValue(path), nil
	}
	return value{}, fmt.Errorf("reads `%s`, which no scenario of this suite models", path)
}

// node is a parsed expression.
type node interface {
	evaluate(context *scenario) (value, error)
	// status reports whether the expression calls a status function anywhere.
	status() bool
}

type literalNode struct{ value value }

func (n literalNode) evaluate(*scenario) (value, error) { return n.value, nil }

func (literalNode) status() bool { return false }

type propertyNode struct{ path string }

func (n propertyNode) evaluate(context *scenario) (value, error) { return context.property(n.path) }

func (propertyNode) status() bool { return false }

type notNode struct{ operand node }

func (n notNode) evaluate(context *scenario) (value, error) {
	operand, err := n.operand.evaluate(context)
	if err != nil {
		return value{}, err
	}
	return booleanValue(!operand.truthy()), nil
}

func (n notNode) status() bool { return n.operand.status() }

// logicalNode is `&&` or `||`. Like GitHub, it returns an operand rather than a boolean, and reads
// the right one only when the left does not decide.
type logicalNode struct {
	and         bool
	left, right node
}

func (n logicalNode) evaluate(context *scenario) (value, error) {
	left, err := n.left.evaluate(context)
	if err != nil {
		return value{}, err
	}
	if left.truthy() != n.and {
		return left, nil
	}
	return n.right.evaluate(context)
}

func (n logicalNode) status() bool { return n.left.status() || n.right.status() }

// comparisonNode is one of `==`, `!=`, `<`, `<=`, `>` and `>=`.
type comparisonNode struct {
	operator    string
	left, right node
}

func (n comparisonNode) evaluate(context *scenario) (value, error) {
	left, err := n.left.evaluate(context)
	if err != nil {
		return value{}, err
	}
	right, err := n.right.evaluate(context)
	if err != nil {
		return value{}, err
	}
	switch n.operator {
	case "==":
		return booleanValue(equal(left, right)), nil
	case "!=":
		return booleanValue(!equal(left, right)), nil
	}
	sign, ordered := order(left, right)
	verdicts := map[string]bool{"<": sign < 0, "<=": sign <= 0, ">": sign > 0, ">=": sign >= 0}
	return booleanValue(ordered && verdicts[n.operator]), nil
}

func (n comparisonNode) status() bool { return n.left.status() || n.right.status() }

// callNode is a function call; the name is matched ignoring case, as GitHub matches it.
type callNode struct {
	name      string
	arguments []node
}

// statusFunctions are the functions that decide whether a condition gets the implicit `success()`.
func statusFunctions() map[string]func(*scenario) bool {
	return map[string]func(*scenario) bool{
		"success":   func(s *scenario) bool { return !s.failed && !s.cancelled },
		"failure":   func(s *scenario) bool { return s.failed },
		"cancelled": func(s *scenario) bool { return s.cancelled },
		"always":    func(*scenario) bool { return true },
	}
}

// stringFunctionArity is how many arguments a string function takes: the text, and what to look for.
const stringFunctionArity = 2

// stringFunctions compare their two arguments as strings, ignoring case.
func stringFunctions() map[string]func(text, search string) bool {
	return map[string]func(text, search string) bool{
		"startswith": strings.HasPrefix,
		"endswith":   strings.HasSuffix,
		"contains":   strings.Contains,
	}
}

func (n callNode) evaluate(context *scenario) (value, error) {
	name := strings.ToLower(n.name)
	arguments := make([]value, 0, len(n.arguments))
	for _, argument := range n.arguments {
		evaluated, err := argument.evaluate(context)
		if err != nil {
			return value{}, err
		}
		arguments = append(arguments, evaluated)
	}
	if outcome, found := statusFunctions()[name]; found {
		if len(arguments) != 0 {
			return value{}, fmt.Errorf("%s() takes no argument", n.name)
		}
		return booleanValue(outcome(context)), nil
	}
	if compare, found := stringFunctions()[name]; found {
		if len(arguments) != stringFunctionArity {
			return value{}, fmt.Errorf("%s() takes two arguments", n.name)
		}
		return booleanValue(compare(strings.ToUpper(arguments[0].cast()), strings.ToUpper(arguments[1].cast()))), nil
	}
	if name == "hashfiles" && len(arguments) > 0 {
		if context.files {
			return textValue("0123456789abcdef"), nil
		}
		return textValue(""), nil
	}
	return value{}, fmt.Errorf("calls %s(), which this evaluator does not model", n.name)
}

func (n callNode) status() bool {
	if _, found := statusFunctions()[strings.ToLower(n.name)]; found {
		return true
	}
	for _, argument := range n.arguments {
		if argument.status() {
			return true
		}
	}
	return false
}

// wrappedCondition is a condition written inside `${{ }}`, which a job or step `if:` may be.
var wrappedCondition = regexp.MustCompile(`(?s)^\$\{\{(.*)\}\}$`)

// holds reports whether a condition lets its job or step run in the scenario: an empty one is
// `success()`, and one that calls no status function is `success() && (...)`, as GitHub reads it.
func holds(condition string, context *scenario) (bool, error) {
	condition = strings.TrimSpace(condition)
	if wrapped := wrappedCondition.FindStringSubmatch(condition); wrapped != nil {
		condition = strings.TrimSpace(wrapped[1])
	}
	success := !context.failed && !context.cancelled
	if condition == "" {
		return success, nil
	}
	tree, err := parse(condition)
	if err != nil {
		return false, err
	}
	result, err := tree.evaluate(context)
	if err != nil {
		return false, err
	}
	if !tree.status() {
		return success && result.truthy(), nil
	}
	return result.truthy(), nil
}

// tokenKind is the type of a lexical token.
type tokenKind int

const (
	stringToken tokenKind = iota
	numberToken
	nameToken
	operatorToken
	openToken
	closeToken
	commaToken
)

type token struct {
	kind tokenKind
	text string
}

var (
	// nameText is a context property or a function name: dotted segments of letters, digits, `_`
	// and `-`, none starting with a digit or `-`.
	nameText = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_-]*(?:\.[A-Za-z_][A-Za-z0-9_-]*)*`)
	// numberText is a number literal, a JSON number.
	numberText = regexp.MustCompile(`^-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][-+]?[0-9]+)?`)
	// errEnd is the end of an expression reached before what it needed.
	errEnd = errors.New("ends where an operand or a closing parenthesis was expected")
)

// operators are the operator tokens, two-character ones first so `!=` is never read as `!`.
func operators() []string {
	return []string{"&&", "||", "==", "!=", "<=", ">=", "<", ">", "!"}
}

// punctuation are the one-character tokens that are not operators.
func punctuation() map[byte]tokenKind {
	return map[byte]tokenKind{'(': openToken, ')': closeToken, ',': commaToken}
}

// tokenize splits an expression into tokens.
func tokenize(expression string) ([]token, error) {
	var tokens []token
	rest := strings.TrimSpace(expression)
	for rest != "" {
		next, size, err := nextToken(rest)
		if err != nil {
			return nil, err
		}
		tokens = append(tokens, next)
		rest = strings.TrimLeft(rest[size:], " \t\r\n")
	}
	return tokens, nil
}

// nextToken is the token `rest` starts with and how many bytes it takes.
func nextToken(rest string) (token, int, error) {
	if rest[0] == '\'' {
		return stringLiteral(rest)
	}
	if kind, found := punctuation()[rest[0]]; found {
		return token{kind: kind, text: rest[:1]}, 1, nil
	}
	for _, operator := range operators() {
		if strings.HasPrefix(rest, operator) {
			return token{kind: operatorToken, text: operator}, len(operator), nil
		}
	}
	if found := numberText.FindString(rest); found != "" {
		return token{kind: numberToken, text: found}, len(found), nil
	}
	if found := nameText.FindString(rest); found != "" {
		return token{kind: nameToken, text: found}, len(found), nil
	}
	return token{}, 0, fmt.Errorf("holds %q, which this evaluator does not model", rest)
}

// stringLiteral reads a single-quoted string, in which a quote of its own is written twice.
func stringLiteral(rest string) (token, int, error) {
	var text strings.Builder
	for index := 1; index < len(rest); index++ {
		if rest[index] != '\'' {
			text.WriteByte(rest[index])
			continue
		}
		if index+1 < len(rest) && rest[index+1] == '\'' {
			text.WriteByte('\'')
			index++
			continue
		}
		return token{kind: stringToken, text: text.String()}, index + 1, nil
	}
	return token{}, 0, fmt.Errorf("leaves the string %s open", rest)
}

// parser reads tokens into a tree, by GitHub's precedence: `!`, then the orderings, then `==` and
// `!=`, then `&&`, then `||`.
type parser struct {
	tokens []token
	at     int
}

func parse(expression string) (node, error) {
	tokens, err := tokenize(expression)
	if err != nil {
		return nil, err
	}
	reader := &parser{tokens: tokens}
	tree, err := reader.or()
	if err != nil {
		return nil, err
	}
	if reader.at < len(reader.tokens) {
		return nil, fmt.Errorf("goes on after a whole expression, at %q", reader.tokens[reader.at].text)
	}
	return tree, nil
}

// accept consumes the operator `text` when it is next.
func (p *parser) accept(text string) bool {
	if p.at < len(p.tokens) && p.tokens[p.at].kind == operatorToken && p.tokens[p.at].text == text {
		p.at++
		return true
	}
	return false
}

func (p *parser) or() (node, error) {
	return p.logical(false, p.and)
}

func (p *parser) and() (node, error) {
	return p.logical(true, p.equality)
}

// logical reads one `&&` or `||` level over the level below it.
func (p *parser) logical(and bool, operand func() (node, error)) (node, error) {
	operator := "||"
	if and {
		operator = "&&"
	}
	left, err := operand()
	for err == nil && p.accept(operator) {
		var right node
		right, err = operand()
		left = logicalNode{and: and, left: left, right: right}
	}
	return left, err
}

func (p *parser) equality() (node, error) {
	return p.comparison([]string{"==", "!="}, p.ordering)
}

func (p *parser) ordering() (node, error) {
	return p.comparison([]string{"<=", ">=", "<", ">"}, p.unary)
}

// comparison reads one level of left-associative comparison operators over the level below it.
func (p *parser) comparison(operators []string, operand func() (node, error)) (node, error) {
	left, err := operand()
	for err == nil {
		matched := ""
		for _, operator := range operators {
			if p.accept(operator) {
				matched = operator
				break
			}
		}
		if matched == "" {
			break
		}
		var right node
		right, err = operand()
		left = comparisonNode{operator: matched, left: left, right: right}
	}
	return left, err
}

func (p *parser) unary() (node, error) {
	if p.accept("!") {
		operand, err := p.unary()
		return notNode{operand: operand}, err
	}
	return p.primary()
}

func (p *parser) primary() (node, error) {
	if p.at >= len(p.tokens) {
		return nil, errEnd
	}
	current := p.tokens[p.at]
	p.at++
	switch current.kind {
	case stringToken:
		return literalNode{value: textValue(current.text)}, nil
	case numberToken:
		number, err := strconv.ParseFloat(current.text, 64)
		return literalNode{value: numberValue(number)}, err
	case nameToken:
		return p.named(current.text)
	case openToken:
		inner, err := p.or()
		if err != nil {
			return nil, err
		}
		if p.at >= len(p.tokens) || p.tokens[p.at].kind != closeToken {
			return nil, errors.New("leaves a parenthesis open")
		}
		p.at++
		return inner, nil
	case operatorToken, closeToken, commaToken:
	}
	return nil, fmt.Errorf("has %q where an operand belongs", current.text)
}

// named is a keyword literal, a function call or a context property.
func (p *parser) named(name string) (node, error) {
	keywords := map[string]value{"true": booleanValue(true), "false": booleanValue(false), "null": {}}
	if literal, found := keywords[name]; found {
		return literalNode{value: literal}, nil
	}
	if p.at >= len(p.tokens) || p.tokens[p.at].kind != openToken {
		return propertyNode{path: name}, nil
	}
	if strings.Contains(name, ".") {
		return nil, fmt.Errorf("calls %s(), which is not a function", name)
	}
	p.at++
	call := callNode{name: name}
	if p.at < len(p.tokens) && p.tokens[p.at].kind == closeToken {
		p.at++
		return call, nil
	}
	for {
		argument, err := p.or()
		if err != nil {
			return nil, err
		}
		call.arguments = append(call.arguments, argument)
		if p.at >= len(p.tokens) {
			return nil, errEnd
		}
		separator := p.tokens[p.at]
		p.at++
		if separator.kind == closeToken {
			return call, nil
		}
		if separator.kind != commaToken {
			return nil, fmt.Errorf("has %q between the arguments of %s()", separator.text, name)
		}
	}
}
