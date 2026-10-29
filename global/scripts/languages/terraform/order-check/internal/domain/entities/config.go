package entities

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"

	"github.com/rios0rios0/pipelines/global/scripts/languages/terraform/internal/paths"
)

// ErrConfig is a `.terraform-order.json` the checker cannot use.
var ErrConfig = errors.New("invalid .terraform-order.json")

// Severity is whether a finding fails the check.
type Severity string

const (
	// SeverityError fails CI.
	SeverityError Severity = "error"
	// SeverityWarning is informational.
	SeverityWarning Severity = "warning"
)

// Finding is one thing a file breaks.
type Finding struct {
	Rule     string
	Path     string
	Message  string
	Severity Severity
}

// FileResult is what one file was found to break, and whether `--fix`
// rewrote it.
type FileResult struct {
	Path     string
	Findings []Finding
	Fixed    bool
}

// errorFinding and warningFinding build the two kinds of finding.
func errorFinding(rule, path, message string) Finding {
	return Finding{Rule: rule, Path: path, Message: message, Severity: SeverityError}
}

func warningFinding(rule, path, message string) Finding {
	return Finding{Rule: rule, Path: path, Message: message, Severity: SeverityWarning}
}

// DefaultProviderOrder is the provider ranking, heaviest -- broadest blast
// radius -- first. Derived from the observed convention across the
// reference repositories and extended with the common HashiCorp and
// community providers; a repository overrides it with `provider_order` in
// `.terraform-order.json`. A provider absent from the ranking is unknown: the
// checker never calls one out of order and the fixer never moves one.
func DefaultProviderOrder() []string {
	return []string{
		// cloud platforms
		"azuread", "azurerm", "azapi", "aws", "google", "google-beta", "alicloud", "oci", "ibm",
		// data planes
		"opensearch", "elasticsearch", "elasticstack", "postgresql", "mysql", "mongodbatlas", "snowflake",
		// cluster orchestration
		"helm", "kubernetes", "kubectl", "docker",
		// network / DNS / PKI
		"tls", "cloudflare", "dns", "acme",
		// application / utility services
		"http-request", "vault", "onepassword", "keycloak", "external", "github", "gitlab", "azuredevops",
		"datadog", "pagerduty", "opsgenie", "grafana",
		// trivial / local-only helpers
		"time", "tfe", "null", "http", "random", "local", "archive", "template",
	}
}

// Config is the ranking and the ignore globs a run applies.
type Config struct {
	// Weights rank each provider: lower is heavier, and comes first.
	Weights map[string]int
	ignore  []any
	invalid error
}

// NewConfig ranks providers in `order` and ignores nothing.
func NewConfig(order []string) Config {
	weights := map[string]int{}
	for index, provider := range order {
		weights[provider] = index
	}
	return Config{Weights: weights}
}

// IsIgnored is true when `path`, relative to the repository, matches an
// ignore glob -- `*` crossing directories. An ignore list the checker cannot
// read fails the first file it is asked about, never the files before.
func (c Config) IsIgnored(path string) (bool, error) {
	if c.invalid != nil {
		return false, c.invalid
	}
	for _, pattern := range c.ignore {
		glob, ok := pattern.(string)
		if !ok {
			return false, fmt.Errorf("%w: ignore entry %v is not a string", ErrConfig, pattern)
		}
		if paths.Match(path, glob) {
			return true, nil
		}
	}
	return false, nil
}

// ParseConfig reads `.terraform-order.json`: `{"provider_order": [...],
// "ignore": ["glob", ...]}`, both optional. Either may also be a string, read
// a character at a time, or an object, read by its keys in order -- shapes
// nobody should write, kept because a repository may already have.
func ParseConfig(data []byte) (Config, error) {
	document, err := decodeOrdered(json.NewDecoder(bytes.NewReader(data)))
	if err != nil {
		return Config{}, fmt.Errorf("%w: %w", ErrConfig, err)
	}
	object, ok := document.(orderedObject)
	if !ok {
		return Config{}, fmt.Errorf("%w: the top level is not an object", ErrConfig)
	}
	order := DefaultProviderOrder()
	config := NewConfig(order)
	if value, found := object.get("provider_order"); found {
		items, iterable := iterate(value)
		if !iterable {
			return Config{}, fmt.Errorf("%w: provider_order is not a list", ErrConfig)
		}
		config.Weights = map[string]int{}
		for index, provider := range items {
			switch name := provider.(type) {
			case string:
				config.Weights[name] = index
			case orderedObject, []any:
				return Config{}, fmt.Errorf("%w: provider_order entry %d is not a name", ErrConfig, index)
			}
		}
	}
	if value, found := object.get("ignore"); found {
		items, iterable := iterate(value)
		if !iterable {
			config.invalid = fmt.Errorf("%w: ignore is not a list", ErrConfig)
		}
		config.ignore = items
	}
	return config, nil
}

// iterate is what iterating a JSON value yields -- an array's elements, a
// string's characters, an object's keys -- and false for a value that cannot
// be iterated.
func iterate(value any) ([]any, bool) {
	switch typed := value.(type) {
	case []any:
		return typed, true
	case string:
		var characters []any
		for _, r := range typed {
			characters = append(characters, string(r))
		}
		return characters, true
	case orderedObject:
		keys := make([]any, len(typed.keys))
		for i, key := range typed.keys {
			keys[i] = key
		}
		return keys, true
	default:
		return nil, false
	}
}

// orderedObject is a JSON object with its keys in the order they first
// appear; a repeated key keeps its first position and its last value.
type orderedObject struct {
	keys   []string
	values map[string]any
}

func (o orderedObject) get(key string) (any, bool) {
	value, found := o.values[key]
	return value, found
}

// decodeOrdered decodes one JSON document, objects keeping their key order,
// and refuses anything after it.
func decodeOrdered(decoder *json.Decoder) (any, error) {
	decoder.UseNumber()
	value, err := decodeValue(decoder)
	if err != nil {
		return nil, err
	}
	if _, err = decoder.Token(); !errors.Is(err, io.EOF) {
		return nil, errors.New("extra data after the document")
	}
	return value, nil
}

func decodeValue(decoder *json.Decoder) (any, error) {
	token, err := decoder.Token()
	if err != nil {
		return nil, err
	}
	delimiter, isDelimiter := token.(json.Delim)
	if !isDelimiter {
		return token, nil
	}
	if delimiter == '[' {
		var items []any
		for decoder.More() {
			item, itemErr := decodeValue(decoder)
			if itemErr != nil {
				return nil, itemErr
			}
			items = append(items, item)
		}
		_, err = decoder.Token()
		return items, err
	}
	object := orderedObject{values: map[string]any{}}
	for decoder.More() {
		keyToken, keyErr := decoder.Token()
		if keyErr != nil {
			return nil, keyErr
		}
		key, _ := keyToken.(string)
		value, valueErr := decodeValue(decoder)
		if valueErr != nil {
			return nil, valueErr
		}
		if _, seen := object.values[key]; !seen {
			object.keys = append(object.keys, key)
		}
		object.values[key] = value
	}
	_, err = decoder.Token()
	return object, err
}
