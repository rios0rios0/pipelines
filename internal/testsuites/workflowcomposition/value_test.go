package main

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestValueTruthy(t *testing.T) {
	t.Parallel()

	cases := map[string]struct {
		text string
		want bool
	}{
		"should be false when the value is null":            {"v: ~", false},
		"should be false when the value is the false flag":  {"v: false", false},
		"should be false when the value is zero":            {"v: 0", false},
		"should be false when the value is a zero float":    {"v: 0.0", false},
		"should be false when the value is an empty string": {"v: ''", false},
		"should be false when the value is an empty list":   {"v: []", false},
		"should be false when the value is an empty map":    {"v: {}", false},
		"should be true when the value is a NaN":            {"v: .nan", true},
		"should be true when the value is a string":         {"v: x", true},
		"should be true when the value is a list":           {"v: [0]", true},
	}
	for name, values := range cases {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			// given
			document := parsed(t, values.text)

			// when
			got := document.get("v").truthy()

			// then
			assert.Equal(t, values.want, got)
		})
	}

	t.Run("should be false when the key is absent", func(t *testing.T) {
		t.Parallel()
		// given
		document := parsed(t, "v: 1")

		// when
		got := document.get("missing").truthy()

		// then
		assert.False(t, got)
	})
}

func TestValueLookups(t *testing.T) {
	t.Parallel()

	t.Run("should match only a string key when a lookup names one", func(t *testing.T) {
		t.Parallel()
		// given
		document := parsed(t, "1: integer\n'2': string\n")

		// when
		integer, text := document.get("1"), document.get("2")

		// then
		assert.Nil(t, integer)
		assert.Equal(t, "string", text.str())
	})

	t.Run("should know a key is present when its value is null", func(t *testing.T) {
		t.Parallel()
		// given
		document := parsed(t, "if:\n")

		// when
		present, value := document.has("if"), document.get("if")

		// then
		assert.True(t, present)
		assert.Equal(t, "None", value.str())
	})
}

func TestMappingOr(t *testing.T) {
	t.Parallel()

	t.Run("should read a false value as an empty mapping when nothing is declared", func(t *testing.T) {
		t.Parallel()
		// given
		document := parsed(t, "jobs: []\n")

		// when
		jobs, err := mappingOr(document.get("jobs"), "jobs")

		// then
		require.NoError(t, err)
		assert.Empty(t, jobs.pairs)
	})

	t.Run("should name the shape when a value that is not a mapping is read as one", func(t *testing.T) {
		t.Parallel()
		// given
		document := parsed(t, "jobs: [a]\n")

		// when
		_, err := mappingOr(document.get("jobs"), "jobs")

		// then
		require.EqualError(t, err, "jobs is a sequence, not a mapping")
	})

	t.Run("should name the shape when a value that is not a sequence is read as one", func(t *testing.T) {
		t.Parallel()
		// given
		document := parsed(t, "steps: run\n")

		// when
		_, err := sequenceOr(document.get("steps"), "steps")

		// then
		require.EqualError(t, err, "steps is a string, not a sequence")
	})
}

func TestValueRepr(t *testing.T) {
	t.Parallel()

	t.Run("should print a nested document the way Python prints the dict it read", func(t *testing.T) {
		t.Parallel()
		// given
		document := parsed(t, "a: [1, true, ~, 'it''s']\nb: {c: 2.5}\n")

		// when
		printed := document.repr()

		// then
		assert.Equal(t, `{'a': [1, True, None, "it's"], 'b': {'c': 2.5}}`, printed)
	})

	t.Run("should print None when the value is absent", func(t *testing.T) {
		t.Parallel()
		// given
		var absent *value

		// when
		printed, text := absent.repr(), absent.str()

		// then
		assert.Equal(t, "None", printed)
		assert.Equal(t, "None", text)
	})
}

func TestSameKey(t *testing.T) {
	t.Parallel()

	cases := map[string]struct {
		left, right string
		want        bool
	}{
		"should be one key when two integers are spelled differently":  {"1", "01", true},
		"should be two keys when an integer meets a float":             {"1", "1.0", false},
		"should be two keys when an integer meets a boolean":           {"1", "true", false},
		"should be two keys when a string meets the integer it spells": {"'1'", "1", false},
		"should be one key when both are null":                         {"~", "null", true},
	}
	for name, values := range cases {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			// given
			left := parsed(t, "["+values.left+"]").items[0]
			right := parsed(t, "["+values.right+"]").items[0]

			// when
			got := sameKey(left, right)

			// then
			assert.Equal(t, values.want, got)
		})
	}
}
