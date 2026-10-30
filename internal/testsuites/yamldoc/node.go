// Package yamldoc reads the YAML files this repository's test suites check into
// a tree that keeps every mapping in document order, and renders its values the
// way the suites' messages have always spelled them.
//
// The reader is stricter than the YAML library underneath it, on purpose: a file
// the suites cannot read the way GitHub Actions and Azure DevOps read it must
// fail the check that reads it, never pass that check for having nothing in it.
// So a duplicate mapping key, a merge key (`<<`), a second document and a tag
// outside YAML's core schema are all errors -- the last one unless the caller
// accepts application tags, which a CloudFormation template carries.
package yamldoc

// Kind is the type a YAML value resolves to under the core schema.
type Kind int

const (
	// Null is `~`, `null`, an empty value -- and an absent one.
	Null Kind = iota
	// Bool is `true` or `false`.
	Bool
	// Int is an integer, in any base YAML allows.
	Int
	// Float is a floating-point number, `.inf` and `.nan` included.
	Float
	// String is every other scalar: a timestamp or binary value reads as its text.
	String
	// Mapping is a set of key/value pairs, kept in document order.
	Mapping
	// Sequence is a list of values.
	Sequence
)

// Node is one value of a document.
//
// A nil *Node is an ABSENT value -- what a lookup of a missing key returns --
// and every method accepts one, so a chain of lookups needs no guard between
// its links: `job.Get("with").Get("path")` is nil when either key is missing.
type Node struct {
	kind  Kind
	text  string // the scalar as resolved: a String's value, an Int's decimal digits
	value bool   // a Bool's value
	float float64
	line  int
	pairs []Pair
	items []*Node
}

// Pair is one entry of a mapping.
type Pair struct {
	Key   *Node
	Value *Node
}

// Kind is the type of the value; an absent value is Null.
func (n *Node) Kind() Kind {
	if n == nil {
		return Null
	}
	return n.kind
}

// Line is the 1-based line the value starts on, or 0 for an absent one.
func (n *Node) Line() int {
	if n == nil {
		return 0
	}
	return n.line
}

// Get is the value of the mapping entry whose key is the string `key`, or nil
// when the node is not a mapping or has no such key.
func (n *Node) Get(key string) *Node {
	if n.Kind() != Mapping {
		return nil
	}
	for _, pair := range n.pairs {
		if pair.Key.Is(key) {
			return pair.Value
		}
	}
	return nil
}

// Has reports whether the node is a mapping with an entry for `key`, whatever
// that entry's value is.
func (n *Node) Has(key string) bool {
	if n.Kind() != Mapping {
		return false
	}
	for _, pair := range n.pairs {
		if pair.Key.Is(key) {
			return true
		}
	}
	return false
}

// Pairs are a mapping's entries in document order; nil for any other node.
func (n *Node) Pairs() []Pair {
	if n.Kind() != Mapping {
		return nil
	}
	return n.pairs
}

// Items are a sequence's values; nil for any other node.
func (n *Node) Items() []*Node {
	if n.Kind() != Sequence {
		return nil
	}
	return n.items
}

// IsString reports whether the node is a string.
func (n *Node) IsString() bool {
	return n.Kind() == String
}

// Text is a string's value, and "" for any other node.
func (n *Node) Text() string {
	if n.Kind() != String {
		return ""
	}
	return n.text
}

// Is reports whether the node is the string `value`. A number or a boolean
// never equals a string, however it is spelled.
func (n *Node) Is(value string) bool {
	return n.Kind() == String && n.text == value
}

// IsTrue reports whether the node is the boolean `true` -- not merely a value
// that reads as true, which Truthy answers.
func (n *Node) IsTrue() bool {
	return n.Kind() == Bool && n.value
}

// IsFalseOrNull reports whether the node is absent, null, or a false or zero
// value -- every value that compares equal to `false` or to null.
func (n *Node) IsFalseOrNull() bool {
	switch n.Kind() {
	case Null:
		return true
	case Bool:
		return !n.value
	case Int:
		return n.text == "0"
	case Float:
		return n.float == 0
	case String, Mapping, Sequence:
		return false
	}
	return false
}

// Truthy reports whether the value counts as set: an absent or null value, a
// false or zero one, and an empty string, mapping or sequence do not.
func (n *Node) Truthy() bool {
	switch n.Kind() {
	case Null:
		return false
	case Bool:
		return n.value
	case Int:
		return n.text != "0"
	case Float:
		return n.float != 0
	case String:
		return n.text != ""
	case Mapping:
		return len(n.pairs) > 0
	case Sequence:
		return len(n.items) > 0
	}
	return false
}

// Strings are every string the value holds -- mapping keys included, in
// document order -- or the value itself when it is a string.
func (n *Node) Strings() []string {
	var found []string
	n.collectStrings(&found)
	return found
}

func (n *Node) collectStrings(found *[]string) {
	switch n.Kind() {
	case String:
		*found = append(*found, n.text)
	case Mapping:
		for _, pair := range n.pairs {
			pair.Key.collectStrings(found)
			pair.Value.collectStrings(found)
		}
	case Sequence:
		for _, item := range n.items {
			item.collectStrings(found)
		}
	case Null, Bool, Int, Float:
	}
}
