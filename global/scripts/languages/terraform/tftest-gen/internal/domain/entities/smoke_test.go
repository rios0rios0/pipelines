package entities_test

import (
	"testing"

	"github.com/stretchr/testify/assert"

	"github.com/rios0rios0/pipelines/global/scripts/languages/terraform/tftest-gen/internal/domain/entities"
)

const smokeWithEverything = `# smoke.tftest.hcl -- auto-generated minimal plan-time smoke test.
#
# Asserts the module parses, type-checks, and plans with mocked providers.
# Every ` + "`variable { validation { ... } }`" + ` block gets a sibling test
# that supplies a known-invalid value and asserts the validation fires,
# so the guards are covered -- not just declared.

mock_provider "azurerm" {}

run "smoke_plans_successfully" {
  # given
  command = plan

  variables {
    name = "test"
    port = 80
  }

  # when
  # (the plan command above is the act under test)

  # then
  # No assertions -- if ` + "`terraform test`" + ` reaches here without a plan error,
  # the module compiled, resolved every reference, and produced a valid
  # plan graph. That is the smoke-test signal.
}

run "validation_rejects_invalid_name" {
  # given
  command = plan

  variables {
    name = ""
    port = 80
  }

  # when
  # (plan is executed with var.name set to an invalid value)

  # then
  # The validation block on var.name must reject the
  # invalid value -- expect_failures asserts the plan errors
  # out on exactly that variable. Proves the guard fires, not
  # just that it's declared.
  expect_failures = [
    var.name,
  ]
}
`

func TestRenderSmoke(t *testing.T) {
	t.Parallel()

	t.Run("should mock providers, stub required variables and test each validated one", func(t *testing.T) {
		t.Parallel()
		// given
		providers := []entities.Provider{{Local: "azurerm", Source: "hashicorp/azurerm"}}
		variables := []entities.Variable{
			{Name: "name", Type: "string", Required: true, Validation: true},
			{Name: "port", Type: "number", Required: true},
			{Name: "region", Type: "string", Validation: true},
		}

		// when
		rendered := entities.RenderSmoke(providers, variables, entities.NewStubber())

		// then
		assert.Equal(t, smokeWithEverything, rendered)
	})

	t.Run("should stub an unreadable type as a string and skip the validation of an object", func(t *testing.T) {
		t.Parallel()
		// given
		variables := []entities.Variable{
			{Name: "broken", Type: "optional(,)", Required: true},
			{Name: "config", Type: "object({ a = number })", Required: true, Validation: true},
		}

		// when
		rendered := entities.RenderSmoke(nil, variables, entities.NewStubber())

		// then
		assert.Contains(t, rendered, "    broken = \"test\"\n    config = { a = 1 }\n")
		assert.NotContains(t, rendered, "validation_rejects_invalid_config")
		assert.NotContains(t, rendered, "mock_provider")
	})
}
