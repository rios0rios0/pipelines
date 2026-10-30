// Package documents reads the YAML templates and XML reports that
// .github/tests/test-dart-pipeline.sh asserts on, so that suite needs no Python.
//
// A YAML document is printed as JSON, and the suite asks jq the questions it
// used to ask PyYAML: GitHub Actions' `on:` stays the string key `on` (YAML 1.2,
// where PyYAML's YAML 1.1 read it as the boolean true), GitLab's `!reference`
// and other custom tags are kept as their plain values, anchors are resolved,
// merge keys are applied, and a repeated key keeps its last value -- which is
// what PyYAML's safe loader did with each.
//
// An XML report is checked for well-formedness strictly, the way the parsers
// that publish it (Azure DevOps, GitLab, a JUnit reader) would refuse it:
// matching tags, quoted attributes, escaped `&` and `<`, legal characters, and
// exactly one root element.
package documents

import (
	"bytes"
	"encoding/json"
	"encoding/xml"
	"errors"
	"fmt"
	"io"
	"math"
	"os"

	"go.yaml.in/yaml/v4"
)

const (
	exitOK    = 0
	exitBad   = 1
	exitUsage = 2
)

// ErrSeveralDocuments is returned for a YAML stream holding more than one
// document, which PyYAML's `yaml.load` refused too.
var ErrSeveralDocuments = errors.New("expected a single document in the stream")

// ErrNoRoot is returned for an XML document without an element.
var ErrNoRoot = errors.New("no root element")

// ErrSeveralRoots is returned for an XML document with more than one element
// at the top level.
var ErrSeveralRoots = errors.New("junk after the document element")

// ErrTextOutsideRoot is returned for text outside the root element.
var ErrTextOutsideRoot = errors.New("text outside the root element")

// ErrUnsupportedNode is returned for a YAML node of a kind the converter does
// not know, which only a newer YAML library could produce.
var ErrUnsupportedNode = errors.New("unsupported YAML node")

// Run is the command line, returning its exit status:
//
//	dartpipeline yaml <file>      print the document as JSON (exit 1 when it is not valid YAML)
//	dartpipeline xml <file>...    exit 1, naming the file, unless every file is well-formed XML
func Run(args []string, stdout, stderr io.Writer) int {
	commands := map[string]func([]string, io.Writer, io.Writer) int{
		"yaml": runYAML,
		"xml":  runXML,
	}
	if len(args) > 0 {
		if command, ok := commands[args[0]]; ok {
			return command(args[1:], stdout, stderr)
		}
	}
	fmt.Fprintln(stderr, "usage: dartpipeline yaml <file> | dartpipeline xml <file>...")
	return exitUsage
}

func runYAML(args []string, stdout, stderr io.Writer) int {
	if len(args) != 1 {
		fmt.Fprintln(stderr, "usage: dartpipeline yaml <file>")
		return exitUsage
	}
	data, err := os.ReadFile(args[0])
	if err == nil {
		data, err = YAMLToJSON(data)
	}
	if err != nil {
		fmt.Fprintf(stderr, "%s: %v\n", args[0], err)
		return exitBad
	}
	fmt.Fprintf(stdout, "%s\n", data)
	return exitOK
}

func runXML(args []string, _ io.Writer, stderr io.Writer) int {
	if len(args) == 0 {
		fmt.Fprintln(stderr, "usage: dartpipeline xml <file>...")
		return exitUsage
	}
	for _, path := range args {
		data, err := os.ReadFile(path)
		if err == nil {
			err = CheckXML(data)
		}
		if err != nil {
			fmt.Fprintf(stderr, "%s: %v\n", path, err)
			return exitBad
		}
	}
	return exitOK
}

// YAMLToJSON converts one YAML document to JSON. An empty stream is `null`.
func YAMLToJSON(data []byte) ([]byte, error) {
	decoder := yaml.NewDecoder(bytes.NewReader(data))
	var document yaml.Node
	err := decoder.Decode(&document)
	if errors.Is(err, io.EOF) {
		return []byte("null"), nil
	}
	if err != nil {
		return nil, fmt.Errorf("invalid YAML: %w", err)
	}
	var next yaml.Node
	if err = decoder.Decode(&next); !errors.Is(err, io.EOF) {
		if err != nil {
			return nil, fmt.Errorf("invalid YAML: %w", err)
		}
		return nil, ErrSeveralDocuments
	}
	value, err := convert(&document)
	if err != nil {
		return nil, err
	}
	return json.Marshal(value)
}

func convert(node *yaml.Node) (any, error) {
	switch node.Kind {
	case yaml.DocumentNode:
		if len(node.Content) == 0 {
			return json.RawMessage("null"), nil
		}
		return convert(node.Content[0])
	case yaml.SequenceNode:
		return sequence(node)
	case yaml.MappingNode:
		return mapping(node)
	case yaml.ScalarNode:
		return scalar(node)
	case yaml.AliasNode:
		return convert(node.Alias)
	}
	return nil, fmt.Errorf("%w of kind %d", ErrUnsupportedNode, node.Kind)
}

func sequence(node *yaml.Node) ([]any, error) {
	items := make([]any, 0, len(node.Content))
	for _, child := range node.Content {
		item, err := convert(child)
		if err != nil {
			return nil, err
		}
		items = append(items, item)
	}
	return items, nil
}

// mapping keys every value by its key's text, so a key PyYAML would have read
// as a boolean or a number is still found by name. A key written twice keeps
// its last value; keys a merge (`<<`) brings in never replace one written in
// the mapping itself, and an earlier merge wins over a later one.
func mapping(node *yaml.Node) (map[string]any, error) {
	result := map[string]any{}
	var merges []*yaml.Node
	for i := 0; i+1 < len(node.Content); i += 2 {
		key, value := node.Content[i], node.Content[i+1]
		if key.ShortTag() == "!!merge" {
			merges = append(merges, value)
			continue
		}
		converted, err := convert(value)
		if err != nil {
			return nil, err
		}
		result[key.Value] = converted
	}
	for _, merge := range merges {
		if err := applyMerge(result, merge); err != nil {
			return nil, err
		}
	}
	return result, nil
}

func applyMerge(result map[string]any, merge *yaml.Node) error {
	sources := []*yaml.Node{merge}
	if resolved := resolveAlias(merge); resolved.Kind == yaml.SequenceNode {
		sources = resolved.Content
	}
	for _, source := range sources {
		value, err := convert(source)
		if err != nil {
			return err
		}
		merged, ok := value.(map[string]any)
		if !ok {
			continue
		}
		for key, item := range merged {
			if _, present := result[key]; !present {
				result[key] = item
			}
		}
	}
	return nil
}

func resolveAlias(node *yaml.Node) *yaml.Node {
	for node.Kind == yaml.AliasNode {
		node = node.Alias
	}
	return node
}

// scalar keeps booleans, numbers and null typed, and everything else -- custom
// tags included -- as the text it was written as. A non-finite float has no
// JSON form, so it stays text too.
func scalar(node *yaml.Node) (any, error) {
	switch node.ShortTag() {
	case "!!null":
		return json.RawMessage("null"), nil
	case "!!bool", "!!int", "!!float":
		var value any
		if err := node.Decode(&value); err != nil {
			return nil, fmt.Errorf("invalid YAML scalar %q: %w", node.Value, err)
		}
		if number, ok := value.(float64); ok && (math.IsNaN(number) || math.IsInf(number, 0)) {
			return node.Value, nil
		}
		return value, nil
	default:
		return node.Value, nil
	}
}

// CheckXML returns why data is not a well-formed XML document, or nil.
func CheckXML(data []byte) error {
	decoder := xml.NewDecoder(bytes.NewReader(data))
	depth, roots := 0, 0
	for {
		token, err := decoder.Token()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return err
		}
		switch element := token.(type) {
		case xml.StartElement:
			if depth == 0 {
				roots++
			}
			if roots > 1 {
				return ErrSeveralRoots
			}
			depth++
		case xml.EndElement:
			depth--
		case xml.CharData:
			if depth == 0 && len(bytes.TrimSpace(element)) > 0 {
				return ErrTextOutsideRoot
			}
		}
	}
	if roots == 0 {
		return ErrNoRoot
	}
	return nil
}
