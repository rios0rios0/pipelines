package main

import (
	"fmt"
	"math"
	"math/big"
	"strings"
)

// How Python and YAML name the absent value.
const (
	pythonNone = "None"
	nullName   = "null"
)

// valueKind is the type a YAML node resolves to.
type valueKind int

const (
	nullKind valueKind = iota
	boolKind
	intKind
	floatKind
	stringKind
	sequenceKind
	mappingKind
)

// value is one resolved YAML node: a scalar of YAML 1.2's core types, a sequence, or a mapping
// whose pairs keep the order the document wrote them in, so findings come out in document order.
//
// A Go nil *value is a key the mapping does not have. It reads as null, which is what Python's
// `mapping.get(key)` returned for one.
type value struct {
	kind    valueKind
	boolean bool
	integer *big.Int
	number  float64
	text    string
	items   []*value
	pairs   []pair
}

// pair is one entry of a mapping.
type pair struct {
	key   *value
	value *value
}

func newNull() *value { return &value{kind: nullKind} }

func newBool(boolean bool) *value { return &value{kind: boolKind, boolean: boolean} }

func newString(text string) *value { return &value{kind: stringKind, text: text} }

// is reports whether `v` holds a value of the given kind. An absent key holds null.
func (v *value) is(kind valueKind) bool {
	if v == nil {
		return kind == nullKind
	}
	return v.kind == kind
}

// isString reports whether `v` is the string `text`.
func (v *value) isString(text string) bool {
	return v.is(stringKind) && v.text == text
}

// truthy is Python's truth value of the node: null, false, zero, and an empty string, sequence or
// mapping are false, everything else is true. It is what every `value or {}` in the checks tests.
func (v *value) truthy() bool {
	if v == nil {
		return false
	}
	switch v.kind {
	case nullKind:
		return false
	case boolKind:
		return v.boolean
	case intKind:
		return v.integer.Sign() != 0
	case floatKind:
		return v.number != 0
	case stringKind:
		return v.text != ""
	case sequenceKind:
		return len(v.items) > 0
	case mappingKind:
		return len(v.pairs) > 0
	default:
		return false
	}
}

// get is the value of the string key `key` in a mapping, or nil when it has none. Only a string key
// matches, as only a str key matched in Python: `1:` is not the key "1".
func (v *value) get(key string) *value {
	if !v.is(mappingKind) {
		return nil
	}
	for _, entry := range v.pairs {
		if entry.key.isString(key) {
			return entry.value
		}
	}
	return nil
}

// has reports whether a mapping holds the string key `key`, whatever its value.
func (v *value) has(key string) bool {
	if !v.is(mappingKind) {
		return false
	}
	for _, entry := range v.pairs {
		if entry.key.isString(key) {
			return true
		}
	}
	return false
}

// str is Python's `str()`: a string is itself and everything else is its [value.repr].
func (v *value) str() string {
	if v.is(stringKind) {
		return v.text
	}
	return v.repr()
}

// repr is Python's `repr()` of the value Python would have read: `None`, `True`, `'text'`,
// `['a', 1]`, `{'key': 'value'}`.
func (v *value) repr() string {
	if v == nil {
		return pythonNone
	}
	switch v.kind {
	case nullKind:
		return pythonNone
	case boolKind:
		if v.boolean {
			return "True"
		}
		return "False"
	case intKind:
		return v.integer.String()
	case floatKind:
		return reprFloat(v.number)
	case stringKind:
		return reprString(v.text)
	case sequenceKind:
		items := make([]string, 0, len(v.items))
		for _, item := range v.items {
			items = append(items, item.repr())
		}
		return "[" + strings.Join(items, ", ") + "]"
	case mappingKind:
		entries := make([]string, 0, len(v.pairs))
		for _, entry := range v.pairs {
			entries = append(entries, entry.key.repr()+": "+entry.value.repr())
		}
		return "{" + strings.Join(entries, ", ") + "}"
	default:
		return pythonNone
	}
}

// describe names the kind of value for a finding about a document's shape.
func (v *value) describe() string {
	if v == nil {
		return nullName
	}
	switch v.kind {
	case nullKind:
		return nullName
	case boolKind:
		return "a boolean"
	case intKind:
		return "an integer"
	case floatKind:
		return "a float"
	case stringKind:
		return "a string"
	case sequenceKind:
		return "a sequence"
	case mappingKind:
		return "a mapping"
	default:
		return "an unknown value"
	}
}

// mappingOr is Python's `value or {}` read as a mapping: an absent or false value is an empty
// mapping, and anything else that is not a mapping is a shape `what` cannot have.
func mappingOr(v *value, what string) (*value, error) {
	if !v.truthy() {
		return &value{kind: mappingKind}, nil
	}
	if !v.is(mappingKind) {
		return nil, fmt.Errorf("%s is %s, not a mapping", what, v.describe())
	}
	return v, nil
}

// sequenceOr is Python's `value or []` read as a sequence.
func sequenceOr(v *value, what string) (*value, error) {
	if !v.truthy() {
		return &value{kind: sequenceKind}, nil
	}
	if !v.is(sequenceKind) {
		return nil, fmt.Errorf("%s is %s, not a sequence", what, v.describe())
	}
	return v, nil
}

// sameKey reports whether two mapping keys are the same key: the same type holding the same value,
// as YAML defines node equality. `1` and `01` are one integer key; `1`, `1.0` and `true` are three
// keys, though Python's dict folded them into one.
func sameKey(left, right *value) bool {
	if left.kind != right.kind {
		return false
	}
	switch left.kind {
	case nullKind:
		return true
	case boolKind:
		return left.boolean == right.boolean
	case intKind:
		return left.integer.Cmp(right.integer) == 0
	case floatKind:
		return left.number == right.number
	case stringKind:
		return left.text == right.text
	case sequenceKind, mappingKind:
		return false
	default:
		return false
	}
}

// numberValue is a boolean, integer or float as a float, the way Python orders them against each other:
// `False` and `True` are 0 and 1. Anything else is not a number.
func (v *value) numberValue() (float64, bool) {
	switch v.kind {
	case boolKind:
		if v.boolean {
			return 1, true
		}
		return 0, true
	case intKind:
		number, _ := new(big.Float).SetInt(v.integer).Float64()
		return number, true
	case floatKind:
		return v.number, !math.IsNaN(v.number)
	case nullKind, stringKind, sequenceKind, mappingKind:
		return 0, false
	default:
		return 0, false
	}
}
