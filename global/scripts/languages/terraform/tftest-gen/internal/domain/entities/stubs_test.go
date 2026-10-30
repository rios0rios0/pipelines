package entities_test

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/rios0rios0/pipelines/global/scripts/languages/terraform/tftest-gen/internal/domain/entities"
)

func TestStubberValid(t *testing.T) {
	t.Parallel()

	t.Run("should prefer the name table to the type when the type is a string, number or any", func(t *testing.T) {
		t.Parallel()
		// given
		stubber := entities.NewStubber()

		// when
		location, errLocation := stubber.Valid("string", "location")
		token, errToken := stubber.Valid("any", "api_token")
		plain, errPlain := stubber.Valid("number", "plain")

		// then
		require.NoError(t, errLocation)
		require.NoError(t, errToken)
		require.NoError(t, errPlain)
		assert.Equal(t, `"eastus"`, location)
		assert.Equal(t, `"dummy-value-0000"`, token)
		assert.Equal(t, "1", plain)
	})

	t.Run("should stub collections from their element types and pass the name down", func(t *testing.T) {
		t.Parallel()
		// given
		stubber := entities.NewStubber()

		// when
		list, _ := stubber.Valid("list(string)", "address_space")
		mapped, _ := stubber.Valid("map(number)", "")
		object, _ := stubber.Valid("object({ a = string, b = optional(number), c = bool })", "")
		tuple, _ := stubber.Valid("tuple([string, number])", "")

		// then
		assert.Equal(t, `[["10.0.0.0/16"]]`, list)
		assert.Equal(t, `{ "k" = 1 }`, mapped)
		assert.Equal(t, `{ a = "test", c = true }`, object)
		assert.Equal(t, `["test", 1]`, tuple)
	})

	t.Run("should fail when an optional names no type", func(t *testing.T) {
		t.Parallel()
		// given
		stubber := entities.NewStubber()

		// when
		_, err := stubber.Valid("optional(,)", "x")

		// then
		require.ErrorIs(t, err, entities.ErrNoTypeArgument)
	})

	t.Run("should slice a malformed type to nothing rather than fail", func(t *testing.T) {
		t.Parallel()
		// given
		stubber := entities.NewStubber()

		// when
		stub, err := stubber.Valid("list(", "")

		// then
		require.NoError(t, err)
		assert.Equal(t, `["test"]`, stub)
	})
}

func TestInvalid(t *testing.T) {
	t.Parallel()

	t.Run("should give a type-valid value its validation rejects when the type allows one", func(t *testing.T) {
		t.Parallel()
		// given
		types := []string{"string", "any", "number", "set(string)", "map(any)"}

		// when
		var stubs []string
		for _, typeExpression := range types {
			stub, ok := entities.Invalid(entities.Variable{Type: typeExpression})
			require.True(t, ok)
			stubs = append(stubs, stub)
		}

		// then
		assert.Equal(t, []string{`""`, `""`, "-1", "[]", "{}"}, stubs)
	})

	t.Run("should give nothing when the type needs specific attributes or positions", func(t *testing.T) {
		t.Parallel()
		// given
		types := []string{"bool", "object({ a = string })", "tuple([string])"}

		// when
		var found []bool
		for _, typeExpression := range types {
			_, ok := entities.Invalid(entities.Variable{Type: typeExpression})
			found = append(found, ok)
		}

		// then
		assert.NotContains(t, found, true)
	})
}
