package main

import (
	"strconv"
	"strings"
	"unicode"
)

// tokenKind is what one token of an expression is.
type tokenKind int

const (
	tokenEnd tokenKind = iota
	tokenName
	tokenText
	tokenNumber
	tokenSymbol
)

type token struct {
	kind tokenKind
	text string
}

// functions are the names an expression may call.
func functions() map[string]bool {
	return map[string]bool{functionStep: true, functionIDIndex: true, functionUsesIndex: true}
}

// tokenize splits an expression into names, quoted texts, numbers and symbols.
func tokenize(source string) ([]token, error) {
	var tokens []token
	runes := []rune(source)
	for position := 0; position < len(runes); {
		character := runes[position]
		switch {
		case unicode.IsSpace(character):
			position++
		case character == '_' || unicode.IsLetter(character):
			start := position
			for position < len(runes) && (runes[position] == '_' || unicode.IsLetter(runes[position]) ||
				unicode.IsDigit(runes[position])) {
				position++
			}
			tokens = append(tokens, token{kind: tokenName, text: string(runes[start:position])})
		case unicode.IsDigit(character) || (character == '-' && position+1 < len(runes) && unicode.IsDigit(runes[position+1])):
			start := position
			position++
			for position < len(runes) && unicode.IsDigit(runes[position]) {
				position++
			}
			tokens = append(tokens, token{kind: tokenNumber, text: string(runes[start:position])})
		case character == '\'' || character == '"':
			text, next, err := quoted(runes, position)
			if err != nil {
				return nil, err
			}
			tokens = append(tokens, token{kind: tokenText, text: text})
			position = next
		case strings.ContainsRune("[](),<>", character):
			tokens = append(tokens, token{kind: tokenSymbol, text: string(character)})
			position++
		default:
			return nil, fail("SyntaxError", "invalid character %s", strconv.QuoteRune(character))
		}
	}
	return append(tokens, token{kind: tokenEnd}), nil
}

// quoted reads the quoted text starting at runes[start], where `\\` and an
// escaped quote stand for themselves, and returns it with the position after it.
func quoted(runes []rune, start int) (string, int, error) {
	quote := runes[start]
	var text strings.Builder
	for position := start + 1; position < len(runes); position++ {
		switch runes[position] {
		case quote:
			return text.String(), position + 1, nil
		case '\\':
			if position+1 < len(runes) && (runes[position+1] == quote || runes[position+1] == '\\') {
				position++
			}
		}
		text.WriteRune(runes[position])
	}
	return "", 0, fail("SyntaxError", "unterminated string literal")
}

// parser reads tokens by recursive descent.
type parser struct {
	tokens []token
	at     int
}

func (p *parser) peek() token {
	return p.tokens[p.at]
}

func (p *parser) next() token {
	current := p.tokens[p.at]
	if current.kind != tokenEnd {
		p.at++
	}
	return current
}

func (p *parser) expect(symbol string) error {
	if current := p.next(); current.kind != tokenSymbol || current.text != symbol {
		return fail("SyntaxError", "expected %s", strconv.Quote(symbol))
	}
	return nil
}

// parse reads a whole expression.
func parse(source string) (expression, error) {
	tokens, err := tokenize(source)
	if err != nil {
		return nil, err
	}
	p := &parser{tokens: tokens}
	parsed, err := p.comparison()
	if err != nil {
		return nil, err
	}
	if p.peek().kind != tokenEnd {
		return nil, fail("SyntaxError", "unexpected %s", strconv.Quote(p.peek().text))
	}
	return parsed, nil
}

// comparison is `membership [(<|>) membership]`.
func (p *parser) comparison() (expression, error) {
	left, err := p.membership()
	if err != nil {
		return nil, err
	}
	if current := p.peek(); current.kind == tokenSymbol && (current.text == "<" || current.text == ">") {
		p.next()
		right, rightErr := p.membership()
		if rightErr != nil {
			return nil, rightErr
		}
		return comparison{left: left, right: right, operator: current.text}, nil
	}
	return left, nil
}

// membership is `postfix ['in' postfix]`.
func (p *parser) membership() (expression, error) {
	needle, err := p.postfix()
	if err != nil {
		return nil, err
	}
	if current := p.peek(); current.kind == tokenName && current.text == "in" {
		p.next()
		haystack, haystackErr := p.postfix()
		if haystackErr != nil {
			return nil, haystackErr
		}
		return membership{needle: needle, haystack: haystack}, nil
	}
	return needle, nil
}

// postfix is `primary {'[' literal ']'}`.
func (p *parser) postfix() (expression, error) {
	parsed, err := p.primary()
	if err != nil {
		return nil, err
	}
	for current := p.peek(); current.kind == tokenSymbol && current.text == "["; current = p.peek() {
		p.next()
		key, keyErr := p.literal()
		if keyErr != nil {
			return nil, keyErr
		}
		if keyErr = p.expect("]"); keyErr != nil {
			return nil, keyErr
		}
		parsed = subscript{target: parsed, key: key}
	}
	return parsed, nil
}

// primary is a call, a name or a literal.
func (p *parser) primary() (expression, error) {
	current := p.peek()
	if current.kind != tokenName {
		return p.literal()
	}
	p.next()
	if !functions()[current.text] {
		return name{identifier: current.text}, nil
	}
	if err := p.expect("("); err != nil {
		return nil, err
	}
	steps, err := p.postfix()
	if err != nil {
		return nil, err
	}
	if err = p.expect(","); err != nil {
		return nil, err
	}
	argument, err := p.literal()
	if err != nil {
		return nil, err
	}
	if err = p.expect(")"); err != nil {
		return nil, err
	}
	return call{function: current.text, steps: steps, argument: argument}, nil
}

// literal is a quoted text or an integer.
func (p *parser) literal() (literal, error) {
	current := p.next()
	switch current.kind {
	case tokenText:
		return literal{value: value{kind: textValue, text: current.text}}, nil
	case tokenNumber:
		number, err := strconv.Atoi(current.text)
		if err != nil {
			return literal{}, fail("SyntaxError", "invalid number %s", current.text)
		}
		return literal{value: value{kind: numberValue, number: number}}, nil
	case tokenEnd, tokenName, tokenSymbol:
	}
	return literal{}, fail("SyntaxError", "expected a quoted text or a number, not %s", strconv.Quote(current.text))
}

// The names of the functions an expression may call.
const (
	functionStep      = "step"
	functionIDIndex   = "id_index"
	functionUsesIndex = "uses_index"
)
