package yamldoc_test

import (
	"math"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"

	"github.com/rios0rios0/pipelines/internal/testsuites/yamldoc"
)

func TestNodeLookups(t *testing.T) {
	t.Parallel()

	t.Run("should answer every lookup on an absent value when a key is missing", func(t *testing.T) {
		t.Parallel()
		// given
		document := parse(t, "jobs: {}\n")

		// when
		absent := document.Get("steps").Get("with").Get("path")

		// then
		assert.Nil(t, absent)
		assert.Equal(t, yamldoc.Null, absent.Kind())
		assert.False(t, absent.Has("path"))
		assert.Empty(t, absent.Pairs())
		assert.Empty(t, absent.Items())
		assert.Empty(t, absent.Text())
		assert.Equal(t, "fallback", absent.StrOr("fallback"))
		assert.Equal(t, 0, absent.Line())
	})

	t.Run("should tell a present null from an absent key when both are looked up", func(t *testing.T) {
		t.Parallel()
		// given
		document := parse(t, "name: ~\n")

		// when
		present, missing := document.Get("name"), document.Get("other")

		// then
		assert.True(t, document.Has("name"))
		assert.Equal(t, "None", present.StrOr("fallback"))
		assert.Equal(t, "fallback", missing.StrOr("fallback"))
	})

	t.Run("should compare only strings when a value is matched against text", func(t *testing.T) {
		t.Parallel()
		// given
		document := parse(t, "number: 1\ntext: '1'\nflag: true\n")

		// when
		number, text, flag := document.Get("number"), document.Get("text"), document.Get("flag")

		// then
		assert.False(t, number.Is("1"))
		assert.True(t, text.Is("1"))
		assert.True(t, flag.IsTrue())
		assert.False(t, text.IsTrue())
		assert.Equal(t, 1, number.Line())
	})

	t.Run("should collect every string with mapping keys when a value nests them", func(t *testing.T) {
		t.Parallel()
		// given
		document := parse(t, "inputs:\n  script: run.sh\n  args: [a, 1, {b: c}]\n")

		// when
		found := document.Get("inputs").Strings()

		// then
		assert.Equal(t, []string{"script", "run.sh", "args", "a", "b", "c"}, found)
	})
}

func TestNodeTruth(t *testing.T) {
	t.Parallel()

	cases := map[string]struct {
		text        string
		truthy      bool
		falseOrNull bool
	}{
		"should read null as unset when a value is null": {
			text:        "~",
			truthy:      false,
			falseOrNull: true,
		},
		"should read false as unset when a value is false": {
			text:        "false",
			truthy:      false,
			falseOrNull: true,
		},
		"should read zero as unset when a value is zero": {
			text:        "0",
			truthy:      false,
			falseOrNull: true,
		},
		"should read a zero float as unset when a value is 0.0": {
			text:        "0.0",
			truthy:      false,
			falseOrNull: true,
		},
		"should read an empty string as unset when a value is empty": {
			text:        "''",
			truthy:      false,
			falseOrNull: false,
		},
		"should read an empty mapping as unset when a value is {}": {
			text:        "{}",
			truthy:      false,
			falseOrNull: false,
		},
		"should read an empty sequence as unset when a value is []": {
			text:        "[]",
			truthy:      false,
			falseOrNull: false,
		},
		"should read true as set when a value is true": {
			text:        "true",
			truthy:      true,
			falseOrNull: false,
		},
		"should read a non-zero number as set when a value is a number": {
			text:        "3",
			truthy:      true,
			falseOrNull: false,
		},
		"should read a non-zero float as set when a value is a float": {
			text:        "0.5",
			truthy:      true,
			falseOrNull: false,
		},
		"should read text as set when a value is a non-empty string": {
			text:        "x",
			truthy:      true,
			falseOrNull: false,
		},
		"should read a mapping as set when a value is a non-empty mapping": {
			text:        "{a: 1}",
			truthy:      true,
			falseOrNull: false,
		},
		"should read a sequence as set when a value is a non-empty list": {
			text:        "[1]",
			truthy:      true,
			falseOrNull: false,
		},
	}
	for name, scenario := range cases {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			// given
			value := parse(t, "value: "+scenario.text+"\n").Get("value")

			// when
			truthy, falseOrNull := value.Truthy(), value.IsFalseOrNull()

			// then
			assert.Equal(t, scenario.truthy, truthy)
			assert.Equal(t, scenario.falseOrNull, falseOrNull)
		})
	}
}

func TestRender(t *testing.T) {
	t.Parallel()

	t.Run("should render a value the way the suites' messages spell it when it is printed", func(t *testing.T) {
		t.Parallel()
		// given
		document := parse(t, "value: {name: x, flags: [true, false, ~], count: 3, ratio: 2.50, nested: {a: 'it''s'}}\n")

		// when
		rendered := document.Get("value").Repr()

		// then
		assert.Equal(t,
			`{'name': 'x', 'flags': [True, False, None], 'count': 3, 'ratio': 2.5, 'nested': {'a': "it's"}}`,
			rendered)
		assert.Equal(t, "x", document.Get("value").Get("name").Str())
		assert.Equal(t, "None", document.Get("missing").Str())
	})

	// backslashed writes `|` as a backslash, so an expected escape reads as it prints.
	backslashed := func(text string) string { return strings.ReplaceAll(text, "|", `\`) }
	quotes := map[string]struct {
		text     string
		expected string
	}{
		"should quote with single quotes when the text holds none":          {text: "plain", expected: `'plain'`},
		"should switch to double quotes when the text holds a single quote": {text: "it's", expected: `"it's"`},
		"should escape the single quote when the text holds both quotes": {
			text:     `it's "x"`,
			expected: `'it\'s "x"'`,
		},
		"should escape control characters when the text holds them": {
			text:     "a\tb\nc\rd\x01\x7f\\",
			expected: `'a\tb\nc\rd\x01\x7f\\'`,
		},
		"should keep printable non-ASCII when the text holds it": {
			text:     "caf\xc3\xa9 \xe2\x80\x94 ok",
			expected: "'caf\xc3\xa9 \xe2\x80\x94 ok'",
		},
		"should escape unprintable non-ASCII when the text holds it": {
			text:     "a\xc2\xa0b\xe2\x80\x8bc\U000e0001",
			expected: backslashed("'a|xa0b|u200bc|U000e0001'"),
		},
		"should render an empty string as a pair of quotes when it is empty": {text: "", expected: `''`},
	}
	for name, scenario := range quotes {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			// given
			text := scenario.text

			// when
			quoted := yamldoc.Quote(text)

			// then
			assert.Equal(t, scenario.expected, quoted)
		})
	}
}

func TestFloatRepr(t *testing.T) {
	t.Parallel()

	cases := map[string]struct {
		value    float64
		expected string
	}{
		"should add a fractional zero when the float is integral": {value: 1, expected: "1.0"},
		"should write zero as 0.0 when the float is zero":         {value: 0, expected: "0.0"},
		"should keep the sign when the float is negative zero": {
			value:    math.Copysign(0, -1),
			expected: "-0.0",
		},
		"should write the shortest exact digits when the float is 0.1":  {value: 0.1, expected: "0.1"},
		"should write it out in full when the point is four digits in":  {value: 0.0001, expected: "0.0001"},
		"should use an exponent when the point is five digits in":       {value: 0.00001, expected: "1e-05"},
		"should write it out in full when the float has sixteen digits": {value: 1e15, expected: "1000000000000000.0"},
		"should use an exponent when the float has seventeen digits":    {value: 1e16, expected: "1e+16"},
		"should keep the mantissa digits when an exponent is used":      {value: -1.5e300, expected: "-1.5e+300"},
		"should write infinity as inf when the float is infinite":       {value: math.Inf(1), expected: "inf"},
		"should write negative infinity as -inf when it is":             {value: math.Inf(-1), expected: "-inf"},
		"should write nan as nan when the float is not a number":        {value: math.NaN(), expected: "nan"},
	}
	for name, scenario := range cases {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			// given
			value := scenario.value

			// when
			rendered := yamldoc.FloatRepr(value)

			// then
			assert.Equal(t, scenario.expected, rendered)
		})
	}
}
