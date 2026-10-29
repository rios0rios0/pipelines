package main

import (
	"errors"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

var errUnmodelled = errors.New("not modelled by this test")

// lookupOf answers the given properties, ignoring case as GitHub does, and fails for any other.
func lookupOf(properties map[string]exprValue) lookup {
	return func(path string) (exprValue, error) {
		if property, ok := properties[strings.ToLower(path)]; ok {
			return property, nil
		}
		return exprValue{}, errUnmodelled
	}
}

func TestEvaluateCondition(t *testing.T) {
	t.Parallel()

	properties := map[string]exprValue{
		"github.head_ref":                 exprText("Feat/Add-Logs"),
		"github.event.pull_request.draft": exprBoolean(false),
		"inputs.prefix":                   exprText(""),
		"inputs.nothing":                  {kind: exprNull},
	}
	cases := map[string]struct {
		expression string
		want       bool
	}{
		"should compare strings ignoring case when both sides are strings": {
			"github.head_ref == 'feat/add-logs'", true,
		},
		"should negate a comparison when the operator is !=": {
			"github.head_ref != 'feat/add-logs'", false,
		},
		"should match a prefix ignoring case when startsWith is called": {
			"startsWith(github.head_ref, 'FEAT/')", true,
		},
		"should match a suffix ignoring case when endsWith is called": {
			"endsWith(github.head_ref, '-LOGS')", true,
		},
		"should find a substring ignoring case when contains is called": {
			"contains(github.head_ref, 'add')", true,
		},
		"should treat the empty prefix as a match when startsWith is given one": {
			"startsWith(github.head_ref, inputs.prefix)", true,
		},
		"should cast a boolean to its name when a function takes one": {
			"startsWith(github.event.pull_request.draft, 'fal')", true,
		},
		"should cast null to the empty string when a function takes it": {
			"contains(inputs.nothing, '')", true,
		},
		"should match function names ignoring case when they are written in capitals": {
			"STARTSWITH(github.head_ref, 'feat')", true,
		},
		"should read property names ignoring case when they are written in capitals": {
			"GitHub.Head_Ref == 'feat/add-logs'", true,
		},
		"should bind ! tighter than == when both appear": {
			"!github.head_ref == 'feat/add-logs'", false,
		},
		"should compare a boolean literal when the property is a boolean": {
			"github.event.pull_request.draft == false", true,
		},
		"should return the right operand of && when the left is truthy": {
			"'yes' && inputs.prefix", false,
		},
		"should return the right operand of || when the left is falsy": {
			"inputs.prefix || 'fallback'", true,
		},
		"should coerce both sides to numbers when null meets the empty string": {
			"inputs.nothing == inputs.prefix", true,
		},
		"should coerce both sides to numbers when false meets the empty string": {
			"false == ''", true,
		},
		"should read a JSON number from a string when it meets a boolean": {
			"'1.0' == true", true,
		},
		"should never equal NaN when a string spells no number": {
			"'true' == true", false,
		},
		"should treat the empty string as falsy when it is the result": {
			"inputs.prefix", false,
		},
		"should treat null as falsy when it is the result": {
			"null", false,
		},
		"should replace placeholders and literal braces when format is called": {
			"format('{{{0}}}-{1}', 'a', true) == '{a}-true'", true,
		},
		"should not evaluate the right operand when && is decided by the left": {
			"false && github.unmodelled", false,
		},
		"should not evaluate the right operand when || is decided by the left": {
			"true || github.unmodelled", true,
		},
		"should unescape a doubled quote when a string literal holds one": {
			"'it''s' == 'IT''S'", true,
		},
		"should group with parentheses when they override precedence": {
			"!(github.head_ref == 'x' || github.event.pull_request.draft)", true,
		},
	}
	for name, values := range cases {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			// given
			read := lookupOf(properties)

			// when
			got, err := evaluateCondition(values.expression, read)

			// then
			require.NoError(t, err)
			assert.Equal(t, values.want, got)
		})
	}
}

func TestEvaluateConditionRefusals(t *testing.T) {
	t.Parallel()

	cases := map[string]struct {
		expression string
		reason     string
	}{
		"should refuse a number literal when one is written": {
			"1 == 1",
			`'1' is not part of the expression subset`,
		},
		"should refuse a comparison operator when one is written": {
			"'a' < 'b'",
			`'<' is not part of the expression subset`,
		},
		"should refuse an index when one is written": {
			"github['ref']",
			`'[' is not part of the expression subset`,
		},
		"should refuse a double-quoted string when one is written": {
			`"x" == 'x'`,
			`'"' is not part of the expression subset`,
		},
		"should refuse the ${{ }} wrapper when the condition has one": {
			"${{ true }}",
			`'$' is not part of the expression subset`,
		},
		"should refuse a function it does not model when one is called": {
			"fromJSON('[]')",
			"fromJSON() is not a function",
		},
		"should refuse a wrong number of arguments when startsWith gets one": {
			"startsWith('a')", "startsWith() takes 2 arguments, not 1",
		},
		"should refuse a name that is no literal when it is capitalised": {"True", `"True" is neither a literal`},
		"should refuse a string that is never closed":                    {"'open", "a string literal is never closed"},
		"should refuse a group that is never closed":                     {"(true", "expected ) to close the ("},
		"should refuse tokens left over when the expression ends early":  {"true true", `unexpected "true"`},
		"should refuse an operator with nothing after it":                {"true &&", "expected a value"},
		"should refuse an empty expression":                              {"", "expected a value"},
		"should refuse a property path that ends in a dot": {
			"github.",
			`expected a property name after "github."`,
		},
		"should refuse a format placeholder with no argument": {
			"format('{1}', 'a')",
			`names no argument at "{1}"`,
		},
		"should refuse a format brace that is never closed":  {"format('{0', 'a')", "has an unclosed {"},
		"should refuse a format brace that was never opened": {"format('}', 'a')", "has an unopened }"},
		"should refuse a format placeholder that is not a number": {
			"format('{+0}', 'a')",
			`names no argument at "{+0}"`,
		},
		"should fail when the expression reads a property it is not given": {
			"github.actor == 'x'", errUnmodelled.Error(),
		},
	}
	for name, values := range cases {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			// given
			read := lookupOf(map[string]exprValue{})

			// when
			_, err := evaluateCondition(values.expression, read)

			// then
			require.ErrorContains(t, err, values.reason)
		})
	}
}

func TestEqual(t *testing.T) {
	t.Parallel()

	null := exprValue{kind: exprNull}
	cases := map[string]struct {
		left, right exprValue
		want        bool
	}{
		"should equal itself when both sides are null":                    {null, null, true},
		"should equal zero when null meets false":                         {null, exprBoolean(false), true},
		"should not equal one when null meets true":                       {null, exprBoolean(true), false},
		"should equal the number a string spells when it meets a boolean": {exprText("1"), exprBoolean(true), true},
		"should read an exponent when a string spells one": {
			exprText("1e0"),
			exprBoolean(true),
			true,
		},
		"should not read a hexadecimal string as a number when JSON has none": {
			exprText("0x1"),
			exprBoolean(true),
			false,
		},
		"should not trim a padded number when JSON allows no padding": {
			exprText(" 1"),
			exprBoolean(true),
			false,
		},
	}
	for name, values := range cases {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			// given
			left, right := values.left, values.right

			// when
			got := equal(left, right)

			// then
			assert.Equal(t, values.want, got)
		})
	}
}

func TestFoldHelpers(t *testing.T) {
	t.Parallel()

	t.Run("should match a multi-byte fold when the cases differ in width", func(t *testing.T) {
		t.Parallel()
		// given
		text, kelvin := "Kelvin", "\U0000212aelvin"

		// when
		prefix := hasPrefixFold(text, kelvin)
		suffix := hasSuffixFold("1 KELVIN", "elvin")
		inside := containsFold("absolute KELVIN scale", kelvin)

		// then
		assert.True(t, prefix)
		assert.True(t, suffix)
		assert.True(t, inside)
	})

	t.Run("should not match when the text is shorter than what it is compared with", func(t *testing.T) {
		t.Parallel()
		// given
		text := "ab"

		// when
		prefix := hasPrefixFold(text, "abc")
		suffix := hasSuffixFold(text, "zab")
		inside := containsFold(text, "abc")

		// then
		assert.False(t, prefix)
		assert.False(t, suffix)
		assert.False(t, inside)
	})
}
