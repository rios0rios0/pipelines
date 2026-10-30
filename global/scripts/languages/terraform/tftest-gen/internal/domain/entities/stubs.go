package entities

import (
	"errors"
	"regexp"
	"strings"

	"github.com/rios0rios0/pipelines/global/scripts/languages/terraform/internal/text"
)

// ErrNoTypeArgument is an `optional(...)` with nothing in it to stub.
var ErrNoTypeArgument = errors.New("optional() names no type")

// fallbackStub is what a variable gets when its type cannot be stubbed.
const fallbackStub = `"test"`

// The primitive types the name table may stand in for.
const (
	typeString = "string"
	typeNumber = "number"
	typeAny    = "any"
)

// optionalType is `optional(<type>[, <default>])`.
var optionalType = regexp.MustCompile(`(?s)^optional\((.+)\)\z`)

// nameStub is one entry of the name table: a variable whose name matches
// gets the stub instead of the one its type would give.
type nameStub struct {
	pattern string
	stub    string
}

// nameStubs is the name table, tuned for Azure, Cloudflare, Kubernetes and
// Keycloak modules, in the order it is consulted: the first match wins, so a
// specific name sits above the general suffix that would also match it. A
// pattern ending in `\n?\z` matches at the end of the name, or before a
// trailing line break.
func nameStubs() []nameStub {
	const end = `\n?\z`
	const zeroUUID = `"00000000-0000-0000-0000-000000000000"`
	const subscription = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/test-rg/providers"
	return []nameStub{
		// Azure
		{`^location` + end, `"eastus"`},
		{`^resource_group_name` + end, `"test-rg"`},
		{`^subscription_id` + end, zeroUUID},
		{`^tenant_id` + end, zeroUUID},
		{`^virtual_network_name` + end, `"test-vnet"`},
		{`^subnet_id` + end, `"` + subscription + `/Microsoft.Network/virtualNetworks/vnet/subnets/subnet"`},
		{`^key_vault_id` + end, `"` + subscription + `/Microsoft.KeyVault/vaults/test-kv"`},
		{`address_space` + end, `["10.0.0.0/16"]`},
		{`address_prefix(es)?` + end, `["10.0.0.0/16"]`},
		{`^sku(_tier|_name)?` + end, `"Standard"`},
		// Generic identity
		{`^environment` + end, `"dev"`},
		{`^customer_id` + end, `"1001"`},
		{`^name` + end, fallbackStub},
		{`^name_prefix` + end, fallbackStub},
		{`^name_suffix` + end, fallbackStub},
		// Networking / endpoints
		{`cidr`, `"10.0.0.0/16"`},
		{`^vpc_id` + end, `"vpc-12345678"`},
		{`url` + end, `"https://example.com"`},
		{`host(name)?` + end, `"example.com"`},
		{`endpoint` + end, `"https://example.com"`},
		{`email` + end, `"test@example.com"`},
		// Secrets / tokens
		{`(token|password|secret|api_key|key)` + end, `"dummy-value-0000"`},
		// Numeric sizes
		{`^cpu` + end, "256"},
		{`^memory` + end, "512"},
		{`^port` + end, "80"},
		{`replicas?` + end, "1"},
		{`_count` + end, "1"},
		// Kubernetes
		{`^namespace` + end, `"default"`},
		{`service_account_name` + end, `"test-sa"`},
		// Helm
		{`chart_version` + end, `"1.0.0"`},
		{`image` + end, `"nginx:latest"`},
		{`registry` + end, `"test.azurecr.io"`},
		// Keycloak
		{`^realm_id` + end, `"test-realm"`},
		{`^client_id` + end, `"test-client"`},
		// IDs fallback
		{`guid`, zeroUUID},
		{`_id` + end, `"test-id"`},
	}
}

// compiledStub is a name-table entry ready to match.
type compiledStub struct {
	pattern *regexp.Regexp
	stub    string
}

// Stubber turns a variable's type, and its name where the name says more,
// into a value Terraform accepts for it.
type Stubber struct {
	names []compiledStub
}

// NewStubber compiles the name table.
func NewStubber() *Stubber {
	table := nameStubs()
	names := make([]compiledStub, len(table))
	for i, entry := range table {
		names[i] = compiledStub{pattern: regexp.MustCompile(entry.pattern), stub: entry.stub}
	}
	return &Stubber{names: names}
}

// forName is the stub the name table gives `name`, if any.
func (s *Stubber) forName(name string) (string, bool) {
	for _, entry := range s.names {
		if entry.pattern.MatchString(name) {
			return entry.stub, true
		}
	}
	return "", false
}

// Valid is a type-valid value for a variable of type `typeExpression` called
// `name`, the name table consulted for a string, number or `any`. A type the
// generator cannot read is an error; the caller stubs it as a string.
func (s *Stubber) Valid(typeExpression, name string) (string, error) {
	t := text.Strip(typeExpression)
	if match := optionalType.FindStringSubmatch(t); match != nil {
		first, err := firstTypeArgument(match[1])
		if err != nil {
			return "", err
		}
		return s.Valid(first, name)
	}
	if name != "" && (t == typeString || t == typeNumber || t == typeAny) {
		if stub, found := s.forName(name); found {
			return stub, nil
		}
	}
	if stub, found := scalarStubs()[t]; found {
		return stub, nil
	}
	return s.collection(t, name)
}

// scalarStubs are the stubs of the primitive types.
func scalarStubs() map[string]string {
	return map[string]string{typeString: fallbackStub, typeNumber: "1", "bool": "true", typeAny: fallbackStub}
}

// collection stubs a list, set, map, object or tuple from its element types;
// anything else is a string.
func (s *Stubber) collection(t, name string) (string, error) {
	switch {
	case strings.HasPrefix(t, "list(") || strings.HasPrefix(t, "set("):
		element, err := s.Valid(text.Slice(t, strings.IndexByte(t, '(')+1, -1), name)
		return "[" + element + "]", err
	case strings.HasPrefix(t, "map("):
		element, err := s.Valid(text.Slice(t, len("map("), -1), name)
		return `{ "k" = ` + element + " }", err
	case strings.HasPrefix(t, "object("):
		inner := text.Strip(text.Slice(t, len("object("), -1))
		if strings.HasPrefix(inner, "{") && strings.HasSuffix(inner, "}") {
			inner = text.Slice(inner, 1, -1)
		}
		fields, err := s.objectFields(inner)
		return "{ " + fields + " }", err
	case strings.HasPrefix(t, "tuple("):
		inner := text.Strip(text.Slice(t, len("tuple("), -1))
		if strings.HasPrefix(inner, "[") {
			inner = text.Slice(inner, 1, -1)
		}
		var elements []string
		for _, element := range splitTopLevel(inner, ',') {
			stub, err := s.Valid(element, "")
			if err != nil {
				return "", err
			}
			elements = append(elements, stub)
		}
		return "[" + strings.Join(elements, ", ") + "]", nil
	default:
		return fallbackStub, nil
	}
}

// objectFields stubs every required attribute of an object type; an
// `optional(...)` one is left out.
func (s *Stubber) objectFields(inner string) (string, error) {
	var parts []string
	for _, item := range splitTopLevel(inner, ',') {
		key, fieldType, found := strings.Cut(item, "=")
		if !found {
			continue
		}
		key, fieldType = text.Strip(key), text.Strip(fieldType)
		if strings.HasPrefix(fieldType, "optional(") {
			continue
		}
		stub, err := s.Valid(fieldType, "")
		if err != nil {
			return "", err
		}
		parts = append(parts, key+" = "+stub)
	}
	return strings.Join(parts, ", "), nil
}

// firstTypeArgument is the type an `optional(...)` wraps, its default left
// out.
func firstTypeArgument(arguments string) (string, error) {
	items := splitTopLevel(arguments, ',')
	if len(items) == 0 {
		return "", ErrNoTypeArgument
	}
	return text.Strip(items[0]), nil
}

// splitTopLevel splits a type expression at `separator` outside brackets and
// quotes, a line break counting as a comma too; empty items are dropped.
func splitTopLevel(expression string, separator byte) []string {
	var kept []string
	for _, item := range splitItems(expression, separator) {
		if item != "" {
			kept = append(kept, item)
		}
	}
	return kept
}

// splitItems is splitTopLevel with the empty items kept.
func splitItems(expression string, separator byte) []string {
	var (
		items   []string
		current strings.Builder
	)
	depth := 0
	inString, quote := false, byte(0)
	for i := range len(expression) {
		character := expression[i]
		switch {
		case inString:
			inString = character != quote
		case character == '"' || character == '\'':
			inString, quote = true, character
		default:
			depth += bracketDepth(character)
			if depth == 0 && (character == separator || separator == ',' && character == '\n') {
				items = append(items, text.Strip(current.String()))
				current.Reset()
				continue
			}
		}
		current.WriteByte(character)
	}
	if current.Len() > 0 {
		items = append(items, text.Strip(current.String()))
	}
	return items
}

// bracketDepth is how a character moves bracket depth: up for an opening
// bracket, down for a closing one.
func bracketDepth(character byte) int {
	switch {
	case strings.IndexByte("([{", character) >= 0:
		return 1
	case strings.IndexByte(")]}", character) >= 0:
		return -1
	default:
		return 0
	}
}

// Invalid is a value of the variable's type that its validation should
// reject, so `terraform plan` reaches the validation instead of failing the
// type check first; false for a type with no such value derivable from the
// type alone -- `bool`, `object(...)` and `tuple(...)` need specific
// attributes or positions -- and the caller skips that variable's test.
func Invalid(variable Variable) (string, bool) {
	t := text.Strip(variable.Type)
	switch {
	case strings.HasPrefix(t, typeString) || t == typeAny:
		return `""`, true
	case strings.HasPrefix(t, typeNumber):
		return "-1", true
	case strings.HasPrefix(t, "list(") || strings.HasPrefix(t, "set("):
		return "[]", true
	case strings.HasPrefix(t, "map("):
		return "{}", true
	default:
		return "", false
	}
}
