// Package reports checks the XML reports the Terraform tiers write -- JUnit
// bundles and the generic coverage report -- for the shell suites that
// assert on them.
//
// Well-formedness here is held at least as strictly as a conforming XML
// parser holds it: one root element, no text outside it, matched tags, no
// attribute given twice, no undefined entity, no character XML forbids, a
// declaration only at the very start and a DOCTYPE only before the root, and
// no `--` inside a comment. A report a publisher would reject must fail here.
package reports

import (
	"bytes"
	"encoding/xml"
	"errors"
	"fmt"
	"io"
	"regexp"
	"strconv"
	"strings"
	"unicode/utf8"
)

// The lexical shapes the decoder is lenient about: a start tag whose
// attributes are not separated by whitespace, a processing instruction whose
// target runs into its content or reuses the reserved name `xml`, and an XML
// declaration outside its grammar.
var (
	startTag = regexp.MustCompile(`^<` + qualifiedName + `(?:` + blank + `+` + qualifiedName + blank + `*=` + blank +
		`*(?:"(?:[^"<&]|` + reference + `)*"|'(?:[^'<&]|` + reference + `)*'))*` + blank + `*/?>$`)
	instruction = regexp.MustCompile(`^<\?` + name + `(?:` + blank + `[^?]*(?:\?[^>][^?]*)*)?\?>$`)
	declaration = regexp.MustCompile(`^<\?xml` + blank + `+version` + blank + `*=` + blank +
		`*(?:"1\.[0-9]+"|'1\.[0-9]+')` +
		`(?:` + blank + `+encoding` + blank + `*=` + blank + `*(?:"[A-Za-z][A-Za-z0-9._-]*"|'[A-Za-z][A-Za-z0-9._-]*'))?` +
		`(?:` + blank + `+standalone` + blank + `*=` + blank + `*(?:"(?:yes|no)"|'(?:yes|no)'))?` + blank + `*\?>$`)
)

// Names are read the way a namespace-aware parser reads them: an element or
// attribute is `name` or `prefix:name`, a processing instruction's target is a
// plain name, and no name starts with a colon or holds two.
const (
	name          = `[A-Za-z_][-A-Za-z0-9_.]*`
	qualifiedName = name + `(?::` + name + `)?`
	blank         = `[ \t\r\n]`
	reference     = `&(?:` + name + `|#[0-9]+|#x[0-9A-Fa-f]+);`
	doctype       = "DOCTYPE"
	// declarationTarget is the processing-instruction target of the XML
	// declaration, reserved for it.
	declarationTarget = "xml"
)

var (
	// ErrMalformed is a document that is not well-formed XML.
	ErrMalformed = errors.New("not well-formed")
	// ErrMismatch is a well-formed document that is not the one expected.
	ErrMismatch = errors.New("not as expected")
)

// Element is a parsed element: its name, attributes and child elements.
type Element struct {
	Name       string
	Attributes map[string]string
	Children   []*Element
}

// document tracks what has been read so far, for the rules the decoder
// itself does not enforce.
type document struct {
	stack   []*Element
	root    *Element
	tokens  int
	doctype bool
}

// Parse reads `data` as one well-formed XML document and returns its root.
func Parse(data []byte) (*Element, error) {
	if err := characters(data); err != nil {
		return nil, fmt.Errorf("%w: %w", ErrMalformed, err)
	}
	decoder := xml.NewDecoder(bytes.NewReader(data))
	decoder.Strict = true
	var doc document
	for {
		start := decoder.InputOffset()
		token, err := decoder.Token()
		if errors.Is(err, io.EOF) {
			break
		}
		if err == nil {
			err = lexical(token, data[start:decoder.InputOffset()])
		}
		if err == nil {
			err = doc.accept(token)
		}
		if err != nil {
			return nil, fmt.Errorf("%w: %w", ErrMalformed, err)
		}
		doc.tokens++
	}
	if doc.root == nil {
		return nil, fmt.Errorf("%w: no root element", ErrMalformed)
	}
	return doc.root, nil
}

// characters refuses bytes that are not UTF-8 and characters XML forbids,
// anywhere in the document, comments included.
func characters(data []byte) error {
	if !utf8.Valid(data) {
		return errors.New("invalid UTF-8")
	}
	for _, r := range string(data) {
		if !allowed(r) {
			return fmt.Errorf("character %U is not allowed", r)
		}
	}
	return nil
}

// allowed is a character XML 1.0 permits.
func allowed(r rune) bool {
	return r == '\t' || r == '\n' || r == '\r' || r >= ' ' && r <= '\uD7FF' ||
		r >= '\uE000' && r <= '\uFFFD' || r >= 0x10000 && r <= utf8.MaxRune
}

// lexical checks the raw text of a start tag or processing instruction.
func lexical(token xml.Token, raw []byte) error {
	switch t := token.(type) {
	case xml.StartElement:
		if !startTag.Match(raw) {
			return fmt.Errorf("malformed start tag %q", raw)
		}
	case xml.ProcInst:
		if !instruction.Match(raw) || t.Target != declarationTarget && strings.EqualFold(t.Target, declarationTarget) ||
			t.Target == declarationTarget && !declaration.Match(raw) {
			return fmt.Errorf("malformed processing instruction %q", raw)
		}
	}
	return nil
}

// accept applies the document-level rules to one token.
func (d *document) accept(token xml.Token) error {
	switch t := token.(type) {
	case xml.StartElement:
		return d.start(t)
	case xml.EndElement:
		d.stack = d.stack[:len(d.stack)-1]
	case xml.CharData:
		if len(d.stack) == 0 && strings.TrimSpace(string(t)) != "" {
			return errors.New("text outside the root element")
		}
	case xml.Comment:
		if bytes.Contains(t, []byte("--")) || bytes.HasSuffix(t, []byte("-")) {
			return errors.New("'--' inside a comment")
		}
	case xml.ProcInst:
		if t.Target == declarationTarget && d.tokens > 0 {
			return errors.New("XML declaration not at the start")
		}
	case xml.Directive:
		if d.root != nil || d.doctype || !strings.HasPrefix(string(t), doctype) ||
			len(t) == len(doctype) || !strings.ContainsRune(" \t\r\n", rune(t[len(doctype)])) {
			return fmt.Errorf("a %q that is not one DOCTYPE before the root element", t)
		}
		d.doctype = true
	}
	return nil
}

// start opens an element, refusing a second root and a repeated attribute.
func (d *document) start(t xml.StartElement) error {
	if d.root != nil && len(d.stack) == 0 {
		return errors.New("more than one root element")
	}
	element := &Element{Name: t.Name.Local, Attributes: map[string]string{}}
	for _, attribute := range t.Attr {
		name := attribute.Name.Local
		if attribute.Name.Space != "" {
			name = attribute.Name.Space + ":" + name
		}
		if _, seen := element.Attributes[name]; seen {
			return fmt.Errorf("attribute %q given twice", name)
		}
		element.Attributes[name] = attribute.Value
	}
	if len(d.stack) == 0 {
		d.root = element
	} else {
		parent := d.stack[len(d.stack)-1]
		parent.Children = append(parent.Children, element)
	}
	d.stack = append(d.stack, element)
	return nil
}

// ExpectRoot checks the root's name, the attributes given as `name=value`,
// and, with `children=N`, how many child elements it has.
func ExpectRoot(root *Element, name string, expectations []string) error {
	if root.Name != name {
		return fmt.Errorf("%w: the root element is <%s>, not <%s>", ErrMismatch, root.Name, name)
	}
	for _, expectation := range expectations {
		key, value, found := strings.Cut(expectation, "=")
		if !found {
			return fmt.Errorf("%w: %q is not name=value", ErrMismatch, expectation)
		}
		if key == "children" {
			if strconv.Itoa(len(root.Children)) != value {
				return fmt.Errorf("%w: the root has %d children, not %s", ErrMismatch, len(root.Children), value)
			}
			continue
		}
		if got, ok := root.Attributes[key]; !ok || got != value {
			return fmt.Errorf("%w: %s=%q, not %q", ErrMismatch, key, got, value)
		}
	}
	return nil
}

// ExpectAscendingLines checks the `lineNumber` of every element under the
// root's first child increases strictly: no line out of order, none twice.
func ExpectAscendingLines(root *Element) error {
	if len(root.Children) == 0 {
		return fmt.Errorf("%w: the root has no child element", ErrMismatch)
	}
	previous := 0
	for index, line := range root.Children[0].Children {
		number, err := strconv.Atoi(line.Attributes["lineNumber"])
		if err != nil {
			return fmt.Errorf("%w: line %d has no lineNumber", ErrMismatch, index)
		}
		if index > 0 && number <= previous {
			return fmt.Errorf("%w: lineNumber %d follows %d", ErrMismatch, number, previous)
		}
		previous = number
	}
	return nil
}
