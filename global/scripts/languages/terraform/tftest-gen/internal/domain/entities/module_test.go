package entities_test

import (
	"testing"

	"github.com/stretchr/testify/assert"

	"github.com/rios0rios0/pipelines/global/scripts/languages/terraform/tftest-gen/internal/domain/entities"
)

func TestParseVariables(t *testing.T) {
	t.Parallel()

	t.Run("should read type, default and validation when the block closes at column 0", func(t *testing.T) {
		t.Parallel()
		// given
		source := "variable \"name\" {\n  type = string\n  validation {\n    condition = true\n  }\n}\n\n" +
			"variable \"size\" {\n  type    = object({\n    a = number\n  })\n  default = null\n}\n" +
			"variable \"untyped\" {\n}\n"

		// when
		variables := entities.ParseVariables(source)

		// then
		assert.Equal(t, []entities.Variable{
			{Name: "name", Type: "string", Required: true, Validation: true},
			{Name: "size", Type: "object({\n    a = number\n  })", Required: false},
			{Name: "untyped", Type: "string", Required: true},
		}, variables)
	})

	t.Run("should miss a block whose closing brace is indented", func(t *testing.T) {
		t.Parallel()
		// given
		source := "variable \"a\" {\n  type = number\n  }\n"

		// when
		variables := entities.ParseVariables(source)

		// then
		assert.Empty(t, variables)
	})
}

func TestAttributeExpression(t *testing.T) {
	t.Parallel()

	t.Run("should stop before a second assignment on the same line, a character short", func(t *testing.T) {
		t.Parallel()
		// given
		// The cut lands one character before the name the second `=` assigns,
		// so the value loses its last character. Kept as it has always been:
		// fixing it would change the stub, and so the committed test, of every
		// module declaring a variable this way.
		body := "\n  type = string description = \"inline\"\n"

		// when
		value, found := entities.AttributeExpression(body, "type")

		// then
		assert.True(t, found)
		assert.Equal(t, "strin", value)
	})

	t.Run("should read a value that spans lines inside brackets", func(t *testing.T) {
		t.Parallel()
		// given
		body := "\n  type = list(object({\n    a = string\n  }))\n  default = []\n"

		// when
		value, found := entities.AttributeExpression(body, "type")

		// then
		assert.True(t, found)
		assert.Equal(t, "list(object({\n    a = string\n  }))", value)
	})
}

func TestParseRequiredProviders(t *testing.T) {
	t.Parallel()

	t.Run("should read every entry and its source when the block is well formed", func(t *testing.T) {
		t.Parallel()
		// given
		source := "terraform {\n  required_providers {\n    azurerm = {\n      source = \"hashicorp/azurerm\"\n    }\n" +
			"    helm = { version = \"2.0\" }\n  }\n}\n"

		// when
		providers := entities.ParseRequiredProviders(source)

		// then
		assert.Equal(t, []entities.Provider{
			{Local: "azurerm", Source: "hashicorp/azurerm"},
			{Local: "helm", Source: "unknown"},
		}, providers)
	})

	t.Run("should find nothing when there is no required_providers block", func(t *testing.T) {
		t.Parallel()
		// given
		source := "provider \"azurerm\" {}\n"

		// when
		providers := entities.ParseRequiredProviders(source)

		// then
		assert.Empty(t, providers)
	})
}
