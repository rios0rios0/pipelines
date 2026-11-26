package entities

import (
	"bytes"
	"cmp"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"slices"
	"strconv"
	"strings"
)

const (
	licensesKey = "licenses"
	licenseKey  = "license"
	idKey       = "id"
	nameKey     = "name"

	// licenseChoiceDepth is how many open values a license object sits in, counted from its
	// license choice: the element holding `license`, the `licenses` array and the object holding
	// that array.
	licenseChoiceDepth = 3
)

// ErrNotJSON is a BOM that is not one JSON document.
var ErrNotJSON = errors.New("the BOM is not a JSON document")

// Fix is one license the normalisation rewrote.
type Fix struct {
	// Path is where the license object is, in the notation of Dependency-Track's schema errors:
	// `$.components[11].evidence.licenses[0].license`.
	Path string
	// Written is the id as the generator wrote it.
	Written string
	// Resolution is what it became.
	Resolution Resolution
}

// Normalized is a BOM after its license ids were checked against a LicenseList.
type Normalized struct {
	// Document is the BOM to keep. Without a Fix it is the input itself, byte for byte; with one,
	// only the bytes of the ids rewritten differ.
	Document []byte
	// Checked is how many license ids the BOM holds.
	Checked int
	// Fixes are the licenses rewritten, in the order their objects close: document order, except
	// that a license object inside another comes before it.
	Fixes []Fix
}

// NormalizeLicenses makes every `license.id` of a CycloneDX JSON document one `list` holds.
//
// A license object is the `license` member of an element of a `licenses` array: the shape of every
// license choice the schema has, so a component's licenses, their evidence, the metadata's, a
// service's and those of any nested component are all reached by the one rule. An id the list
// holds stays; `deprecated_<id>` becomes `<id>` when the list holds `<id>`; any other id becomes the
// license's `name`. The value is kept in all three cases, so no license is lost.
//
// The document is rewritten in place rather than re-encoded: each change replaces the bytes of one
// key or one string, so the key order, the indentation and every other byte stay as the generator
// wrote them. An object that already holds both `id` and `name` is left as it is: it is not the
// shape a generator writes, and no rewrite of its id could make it valid.
func NormalizeLicenses(document []byte, list LicenseList) (Normalized, error) {
	var probe json.RawMessage
	if err := json.Unmarshal(document, &probe); err != nil {
		return Normalized{}, fmt.Errorf("%w: %w", ErrNotJSON, err)
	}
	walker := &licenseWalker{document: document, list: list}
	if err := walker.walk(); err != nil {
		return Normalized{}, fmt.Errorf("%w: %w", ErrNotJSON, err)
	}
	return walker.normalized(), nil
}

// span is a byte range of the document: [start, end).
type span struct {
	start int64
	end   int64
}

// licenseObject is what the walk learnt about one license object.
type licenseObject struct {
	path    string
	id      string
	hasID   bool
	hasName bool
	idKey   span
	idValue span
}

// frame is one object or array the walk is inside.
type frame struct {
	object    bool
	expectKey bool
	key       string
	keySpan   span
	index     int
	license   *licenseObject
}

// edit replaces the bytes of one token.
type edit struct {
	at          span
	replacement []byte
}

type licenseWalker struct {
	document []byte
	list     LicenseList
	stack    []*frame
	checked  int
	fixes    []Fix
	edits    []edit
}

// walk reads the document token by token. `InputOffset` is where the last token ended, so the
// bytes a token spans are found without decoding anything twice: between two tokens there is only
// whitespace and a `,` or a `:`, never a quote.
func (w *licenseWalker) walk() error {
	decoder := json.NewDecoder(bytes.NewReader(w.document))
	decoder.UseNumber()
	for {
		before := decoder.InputOffset()
		token, err := decoder.Token()
		if errors.Is(err, io.EOF) {
			return nil
		}
		if err != nil {
			return err
		}
		w.visit(token, before, decoder.InputOffset())
	}
}

func (w *licenseWalker) visit(token json.Token, before, after int64) {
	if delimiter, ok := token.(json.Delim); ok {
		if delimiter == '{' || delimiter == '[' {
			w.open(delimiter == '{')
			return
		}
		w.close()
		return
	}
	top := w.top()
	text, isString := token.(string)
	if isString && top != nil && top.object && top.expectKey {
		w.readKey(top, text, span{start: w.quoteAfter(before), end: after})
		return
	}
	if isString && top != nil && top.license != nil && top.key == idKey {
		top.license.id = text
		top.license.hasID = true
		top.license.idKey = top.keySpan
		top.license.idValue = span{start: w.quoteAfter(before), end: after}
	}
	w.valueRead()
}

func (w *licenseWalker) readKey(top *frame, key string, at span) {
	top.expectKey = false
	top.key = key
	top.keySpan = at
	if top.license != nil && key == nameKey {
		top.license.hasName = true
	}
}

func (w *licenseWalker) open(object bool) {
	var license *licenseObject
	if object && w.atLicense() {
		license = &licenseObject{path: w.path()}
	}
	w.stack = append(w.stack, &frame{object: object, expectKey: object, license: license})
}

func (w *licenseWalker) close() {
	closed := w.stack[len(w.stack)-1]
	w.stack = w.stack[:len(w.stack)-1]
	if closed.license != nil {
		w.finish(closed.license)
	}
	w.valueRead()
}

// valueRead moves the enclosing object on to its next key, or the enclosing array on to its next
// element.
func (w *licenseWalker) valueRead() {
	top := w.top()
	if top == nil {
		return
	}
	if top.object {
		top.expectKey = true
		return
	}
	top.index++
}

// atLicense reports whether the value about to be read is the `license` member of an element of a
// `licenses` array.
func (w *licenseWalker) atLicense() bool {
	if len(w.stack) < licenseChoiceDepth {
		return false
	}
	choice := w.stack[len(w.stack)-licenseChoiceDepth:]
	owner, array, element := choice[0], choice[1], choice[2]
	return owner.object && owner.key == licensesKey &&
		!array.object &&
		element.object && element.key == licenseKey
}

func (w *licenseWalker) finish(license *licenseObject) {
	if !license.hasID {
		return
	}
	w.checked++
	if license.hasName {
		return
	}
	resolution := w.list.Resolve(license.id)
	switch resolution.Verdict {
	case VerdictListed:
		return
	case VerdictRestored:
		w.edits = append(w.edits, edit{at: license.idValue, replacement: quoted(resolution.ID)})
	case VerdictNamed:
		w.edits = append(w.edits, edit{at: license.idKey, replacement: quoted(nameKey)})
	}
	w.fixes = append(w.fixes, Fix{Path: license.path, Written: license.id, Resolution: resolution})
}

func (w *licenseWalker) top() *frame {
	if len(w.stack) == 0 {
		return nil
	}
	return w.stack[len(w.stack)-1]
}

// path is where the value about to be read is.
func (w *licenseWalker) path() string {
	var builder strings.Builder
	builder.WriteString("$")
	for _, open := range w.stack {
		if open.object {
			builder.WriteString("." + open.key)
			continue
		}
		builder.WriteString("[" + strconv.Itoa(open.index) + "]")
	}
	return builder.String()
}

// quoteAfter is where the string token that follows `offset` opens.
func (w *licenseWalker) quoteAfter(offset int64) int64 {
	return offset + int64(bytes.IndexByte(w.document[offset:], '"'))
}

func (w *licenseWalker) normalized() Normalized {
	if len(w.edits) == 0 {
		return Normalized{Document: w.document, Checked: w.checked}
	}
	// A license object closes after every object it holds, so the edits are sorted rather than
	// assumed to arrive in document order.
	slices.SortFunc(w.edits, func(a, b edit) int { return cmp.Compare(a.at.start, b.at.start) })
	var rewritten bytes.Buffer
	rewritten.Grow(len(w.document) + len(w.edits)*len(nameKey))
	var written int64
	for _, change := range w.edits {
		rewritten.Write(w.document[written:change.at.start])
		rewritten.Write(change.replacement)
		written = change.at.end
	}
	rewritten.Write(w.document[written:])
	return Normalized{Document: rewritten.Bytes(), Checked: w.checked, Fixes: w.fixes}
}

// quoted is `text` as a JSON string. Marshalling a string cannot fail.
func quoted(text string) []byte {
	encoded, _ := json.Marshal(text)
	return encoded
}
