package yamldoc

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"math/big"
	"os"
	"strings"

	"go.yaml.in/yaml/v4"
)

// Options changes what the reader accepts.
type Options struct {
	// ApplicationTags accepts a tag outside YAML's core schema -- CloudFormation's
	// `!Sub`, `!GetAtt` -- and reads the tagged value as if it carried none.
	ApplicationTags bool
}

// Load reads and parses the YAML file at `path`.
func Load(path string, options Options) (*Node, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	return Parse(data, options)
}

// Parse reads one YAML document. A stream holding no document at all is one
// null value, as an empty file is; a stream holding two is an error.
func Parse(data []byte, options Options) (*Node, error) {
	decoder := yaml.NewDecoder(bytes.NewReader(data))
	var document yaml.Node
	if err := decoder.Decode(&document); err != nil {
		if errors.Is(err, io.EOF) {
			return &Node{kind: Null, line: 1}, nil
		}
		return nil, err
	}
	var second yaml.Node
	if err := decoder.Decode(&second); !errors.Is(err, io.EOF) {
		if err != nil {
			return nil, err
		}
		return nil, fmt.Errorf("line %d: expected a single document in the stream", second.Line)
	}
	reader := &converter{options: options, expanding: map[*yaml.Node]bool{}}
	return reader.convert(&document)
}

// converter turns the library's node tree into this package's.
type converter struct {
	options Options
	// expanding holds every anchor whose alias is being expanded, so an anchor
	// whose value contains an alias to itself is refused instead of followed
	// forever.
	expanding map[*yaml.Node]bool
}

func (c *converter) convert(node *yaml.Node) (*Node, error) {
	switch node.Kind {
	case yaml.DocumentNode:
		if len(node.Content) == 0 {
			return &Node{kind: Null, line: node.Line}, nil
		}
		return c.convert(node.Content[0])
	case yaml.AliasNode:
		return c.alias(node)
	case yaml.MappingNode:
		return c.mapping(node)
	case yaml.SequenceNode:
		return c.sequence(node)
	case yaml.ScalarNode:
		return c.scalar(node)
	}
	return nil, fmt.Errorf("line %d: unknown YAML node kind %d", node.Line, node.Kind)
}

func (c *converter) alias(node *yaml.Node) (*Node, error) {
	if node.Alias == nil {
		return nil, fmt.Errorf("line %d: alias *%s names no anchor", node.Line, node.Value)
	}
	if c.expanding[node.Alias] {
		return nil, fmt.Errorf("line %d: anchor &%s contains an alias to itself", node.Line, node.Value)
	}
	c.expanding[node.Alias] = true
	defer delete(c.expanding, node.Alias)
	return c.convert(node.Alias)
}

func (c *converter) mapping(node *yaml.Node) (*Node, error) {
	if err := c.checkTag(node, "!!map"); err != nil {
		return nil, err
	}
	result := &Node{kind: Mapping, line: node.Line}
	defined := map[string]int{}
	for index := 0; index+1 < len(node.Content); index += 2 {
		keyNode, valueNode := node.Content[index], node.Content[index+1]
		if keyNode.Kind == yaml.ScalarNode && keyNode.ShortTag() == "!!merge" {
			return nil, fmt.Errorf("line %d: merge keys (`<<`) are not supported", keyNode.Line)
		}
		key, err := c.convert(keyNode)
		if err != nil {
			return nil, err
		}
		value, err := c.convert(valueNode)
		if err != nil {
			return nil, err
		}
		identity := key.identity()
		if first, seen := defined[identity]; seen {
			return nil, fmt.Errorf(
				"line %d: mapping key %s already defined at line %d", keyNode.Line, key.Repr(), first)
		}
		defined[identity] = keyNode.Line
		result.pairs = append(result.pairs, Pair{Key: key, Value: value})
	}
	return result, nil
}

func (c *converter) sequence(node *yaml.Node) (*Node, error) {
	if err := c.checkTag(node, "!!seq"); err != nil {
		return nil, err
	}
	result := &Node{kind: Sequence, line: node.Line, items: make([]*Node, 0, len(node.Content))}
	for _, itemNode := range node.Content {
		item, err := c.convert(itemNode)
		if err != nil {
			return nil, err
		}
		result.items = append(result.items, item)
	}
	return result, nil
}

func (c *converter) scalar(node *yaml.Node) (*Node, error) {
	tag := node.ShortTag()
	if !strings.HasPrefix(tag, "!!") {
		if err := c.checkTag(node, ""); err != nil {
			return nil, err
		}
		// An application tag (`!Sub`) reads its scalar as the text it holds.
		return &Node{kind: String, text: node.Value, line: node.Line}, nil
	}
	result := &Node{line: node.Line}
	switch tag {
	case "!!null":
		result.kind = Null
	case "!!bool":
		result.kind = Bool
		if err := node.Decode(&result.value); err != nil {
			return nil, fmt.Errorf("line %d: %w", node.Line, err)
		}
		result.text = node.Value
	case "!!int":
		number, ok := new(big.Int).SetString(node.Value, 0)
		if !ok {
			return nil, fmt.Errorf("line %d: %q is not an integer", node.Line, node.Value)
		}
		result.kind = Int
		result.text = number.String()
	case "!!float":
		result.kind = Float
		if err := node.Decode(&result.float); err != nil {
			return nil, fmt.Errorf("line %d: %w", node.Line, err)
		}
		result.text = node.Value
	case "!!str", "!!timestamp", "!!binary":
		// GitHub Actions and Azure DevOps read a timestamp or a binary value as
		// the text it is written as, and so does every check here.
		result.kind = String
		result.text = node.Value
	default:
		return nil, fmt.Errorf("line %d: could not determine a constructor for the tag '%s'", node.Line, tag)
	}
	return result, nil
}

// checkTag refuses a tag outside the core schema unless application tags are
// accepted. `expected` is the core tag the node's kind carries when untagged.
func (c *converter) checkTag(node *yaml.Node, expected string) error {
	tag := node.ShortTag()
	switch {
	case tag == expected:
		return nil
	case strings.HasPrefix(tag, "!!"):
		return fmt.Errorf("line %d: could not determine a constructor for the tag '%s'", node.Line, tag)
	case c.options.ApplicationTags:
		return nil
	}
	return fmt.Errorf("line %d: could not determine a constructor for the tag '%s'", node.Line, tag)
}

// identity is what makes two mapping keys the same key: their kind and value.
func (n *Node) identity() string {
	return fmt.Sprintf("%d:%s", n.Kind(), n.Str())
}
