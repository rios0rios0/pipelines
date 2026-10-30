package main

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"math/big"
	"os"
	"slices"

	"go.yaml.in/yaml/v4"
)

// dialect is the YAML a file is written in: which tags it may carry beyond YAML's own.
type dialect int

const (
	// standardYAML is GitHub Actions and Azure DevOps: YAML's own tags and nothing else.
	standardYAML dialect = iota
	// gitlabYAML adds GitLab CI's `!reference [ .job, key ]`, read as the sequence it is written as.
	gitlabYAML
)

// The tags a node can resolve to, as yaml.v3 spells them.
const (
	tagNull      = "!!null"
	tagBool      = "!!bool"
	tagInt       = "!!int"
	tagFloat     = "!!float"
	tagString    = "!!str"
	tagTimestamp = "!!timestamp"
	tagSequence  = "!!seq"
	tagMapping   = "!!map"
	tagMerge     = "!!merge"
	tagReference = "!reference"
)

// errSeveralDocuments is a stream that holds more than the one document a pipeline file is.
var errSeveralDocuments = errors.New("expected a single document in the stream, but found another")

// loadFile reads the one YAML document of a file.
func loadFile(path string, flavor dialect) (*value, error) {
	// Every path is one the suite named or a check derived from the checkout it names.
	data, err := os.ReadFile(path) //nolint:gosec // G703: reading the checkout under test is the check
	if err != nil {
		return nil, err
	}
	return parseDocument(data, flavor)
}

// parseDocument resolves the single document of a YAML stream: an empty stream is null, and a
// stream of several documents is refused.
//
// YAML 1.2 decides the types, not the YAML 1.1 of the PyYAML these checks were first written
// against. YAML 1.2 is what GitHub Actions reads, and the two differ exactly where it shows: `on:`
// is the string key `on` rather than the boolean `true`, and `yes`, `no`, `on` and `off` are
// strings rather than booleans.
//
// A key a mapping repeats is refused rather than resolved to its last value, the way yaml.v3
// refuses one when decoding: a document whose meaning depends on which copy wins is a finding.
func parseDocument(data []byte, flavor dialect) (*value, error) {
	decoder := yaml.NewDecoder(bytes.NewReader(data))
	var document yaml.Node
	if err := decoder.Decode(&document); err != nil {
		if errors.Is(err, io.EOF) {
			return newNull(), nil
		}
		return nil, err
	}
	var another yaml.Node
	if err := decoder.Decode(&another); !errors.Is(err, io.EOF) {
		if err != nil {
			return nil, err
		}
		return nil, errSeveralDocuments
	}
	resolver := converter{flavor: flavor, done: map[*yaml.Node]*value{}, open: map[*yaml.Node]bool{}}
	return resolver.convert(&document)
}

// converter resolves a yaml.v3 node tree into values. An anchored node is resolved once and every
// alias to it shares the result; an alias inside the very node it names is refused, because the
// value would contain itself.
type converter struct {
	flavor dialect
	done   map[*yaml.Node]*value
	open   map[*yaml.Node]bool
}

func (c *converter) convert(node *yaml.Node) (*value, error) {
	switch node.Kind {
	case yaml.DocumentNode:
		if len(node.Content) == 0 {
			return newNull(), nil
		}
		return c.convert(node.Content[0])
	case yaml.AliasNode:
		return c.convert(node.Alias)
	case yaml.ScalarNode, yaml.SequenceNode, yaml.MappingNode:
		return c.resolve(node)
	default:
		return nil, fmt.Errorf("line %d: a node of unknown kind %d", node.Line, node.Kind)
	}
}

// resolve converts a scalar, sequence or mapping once, however many aliases name it.
func (c *converter) resolve(node *yaml.Node) (*value, error) {
	if resolved, ok := c.done[node]; ok {
		return resolved, nil
	}
	if c.open[node] {
		return nil, fmt.Errorf("line %d: an alias refers to the node that contains it", node.Line)
	}
	c.open[node] = true
	var (
		resolved *value
		err      error
	)
	switch node.Kind {
	case yaml.ScalarNode:
		resolved, err = scalar(node)
	case yaml.SequenceNode:
		resolved, err = c.sequence(node)
	case yaml.MappingNode:
		resolved, err = c.mapping(node)
	case yaml.DocumentNode, yaml.AliasNode:
		err = fmt.Errorf("line %d: a %s node cannot be resolved in place", node.Line, kindName(node.Kind))
	}
	delete(c.open, node)
	if err != nil {
		return nil, err
	}
	c.done[node] = resolved
	return resolved, nil
}

func kindName(kind yaml.Kind) string {
	switch kind {
	case yaml.DocumentNode:
		return "document"
	case yaml.AliasNode:
		return "alias"
	case yaml.ScalarNode:
		return "scalar"
	case yaml.SequenceNode:
		return "sequence"
	case yaml.MappingNode:
		return "mapping"
	default:
		return "unknown"
	}
}

// scalar resolves a scalar by the tag YAML gave it. A timestamp stays the text it was written as:
// no check compares dates.
func scalar(node *yaml.Node) (*value, error) {
	switch node.ShortTag() {
	case tagString, tagTimestamp:
		return newString(node.Value), nil
	case tagNull:
		return newNull(), nil
	case tagBool:
		var boolean bool
		if err := node.Decode(&boolean); err != nil {
			return nil, err
		}
		return newBool(boolean), nil
	case tagInt:
		return integer(node)
	case tagFloat:
		var number float64
		if err := node.Decode(&number); err != nil {
			return nil, err
		}
		return &value{kind: floatKind, number: number}, nil
	default:
		return nil, fmt.Errorf("line %d: cannot read a scalar tagged %s", node.Line, node.ShortTag())
	}
}

func integer(node *yaml.Node) (*value, error) {
	var decoded any
	if err := node.Decode(&decoded); err != nil {
		return nil, err
	}
	whole := new(big.Int)
	switch number := decoded.(type) {
	case int:
		whole.SetInt64(int64(number))
	case int64:
		whole.SetInt64(number)
	case uint64:
		whole.SetUint64(number)
	default:
		return nil, fmt.Errorf("line %d: %q does not resolve to an integer", node.Line, node.Value)
	}
	return &value{kind: intKind, integer: whole}, nil
}

func (c *converter) sequence(node *yaml.Node) (*value, error) {
	tag := node.ShortTag()
	if tag != tagSequence && (c.flavor != gitlabYAML || tag != tagReference) {
		return nil, fmt.Errorf("line %d: cannot read a sequence tagged %s", node.Line, tag)
	}
	items := make([]*value, 0, len(node.Content))
	for _, child := range node.Content {
		item, err := c.convert(child)
		if err != nil {
			return nil, err
		}
		items = append(items, item)
	}
	return &value{kind: sequenceKind, items: items}, nil
}

// keyed is a mapping entry with the line its key was written on.
type keyed struct {
	pair

	line int
}

// mapping resolves a mapping, merge keys included: `<<: *base` contributes the pairs of `base`
// (of each mapping in a list, the first one winning), and the mapping's own pairs override them.
func (c *converter) mapping(node *yaml.Node) (*value, error) {
	if tag := node.ShortTag(); tag != tagMapping {
		return nil, fmt.Errorf("line %d: cannot read a mapping tagged %s", node.Line, tag)
	}
	var (
		merged []pair
		own    []keyed
	)
	for index := 0; index+1 < len(node.Content); index += 2 {
		keyNode, valueNode := node.Content[index], node.Content[index+1]
		if keyNode.Kind == yaml.ScalarNode && keyNode.ShortTag() == tagMerge {
			pairs, err := c.mergeSource(valueNode)
			if err != nil {
				return nil, err
			}
			merged = append(merged, pairs...)
			continue
		}
		entry, err := c.entry(keyNode, valueNode, own)
		if err != nil {
			return nil, err
		}
		own = append(own, entry)
	}
	pairs := make([]pair, 0, len(merged)+len(own))
	for _, entry := range merged {
		pairs = place(pairs, entry)
	}
	for _, entry := range own {
		pairs = place(pairs, entry.pair)
	}
	return &value{kind: mappingKind, pairs: pairs}, nil
}

// entry resolves one of a mapping's own pairs, refusing a key the mapping already holds.
func (c *converter) entry(keyNode, valueNode *yaml.Node, earlier []keyed) (keyed, error) {
	key, err := c.convert(keyNode)
	if err != nil {
		return keyed{}, err
	}
	if key.is(sequenceKind) || key.is(mappingKind) {
		return keyed{}, fmt.Errorf("line %d: a mapping key must be a scalar, not %s", keyNode.Line, key.describe())
	}
	for _, previous := range earlier {
		if sameKey(previous.key, key) {
			return keyed{}, fmt.Errorf(
				"line %d: mapping key %q already defined at line %d", keyNode.Line, key.str(), previous.line)
		}
	}
	resolved, err := c.convert(valueNode)
	if err != nil {
		return keyed{}, err
	}
	return keyed{pair: pair{key: key, value: resolved}, line: keyNode.Line}, nil
}

// place adds a pair to a mapping being built: a key it already holds keeps its position and takes
// the new value.
func place(pairs []pair, entry pair) []pair {
	for index := range pairs {
		if sameKey(pairs[index].key, entry.key) {
			pairs[index].value = entry.value
			return pairs
		}
	}
	return append(pairs, entry)
}

// mergeSource is the pairs a merge key contributes, in the order that lets the first mapping of a
// list win: the list is applied last to first.
func (c *converter) mergeSource(node *yaml.Node) ([]pair, error) {
	target := dereference(node)
	switch target.Kind {
	case yaml.MappingNode:
		source, err := c.convert(node)
		if err != nil {
			return nil, err
		}
		return source.pairs, nil
	case yaml.SequenceNode:
		var pairs []pair
		for _, child := range slices.Backward(target.Content) {
			if dereference(child).Kind != yaml.MappingNode {
				return nil, fmt.Errorf("line %d: a merge list may hold only mappings", child.Line)
			}
			source, err := c.convert(child)
			if err != nil {
				return nil, err
			}
			pairs = append(pairs, source.pairs...)
		}
		return pairs, nil
	case yaml.DocumentNode, yaml.ScalarNode, yaml.AliasNode:
		return nil, fmt.Errorf("line %d: a merge key takes a mapping or a list of mappings", node.Line)
	default:
		return nil, fmt.Errorf("line %d: a merge key takes a mapping or a list of mappings", node.Line)
	}
}

// dereference follows an alias to the node it names.
func dereference(node *yaml.Node) *yaml.Node {
	for node.Kind == yaml.AliasNode && node.Alias != nil {
		node = node.Alias
	}
	return node
}
