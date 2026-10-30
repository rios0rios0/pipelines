package commands_test

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/rios0rios0/pipelines/global/scripts/languages/terraform/tftest-gen/internal/domain/commands"
	"github.com/rios0rios0/pipelines/global/scripts/languages/terraform/tftest-gen/internal/domain/entities"
	"github.com/rios0rios0/pipelines/global/scripts/languages/terraform/tftest-gen/internal/test/doubles"
)

func module() *doubles.InMemoryModuleRepository {
	return doubles.NewInMemoryModuleRepository(map[string]string{
		"main.tf": "terraform {\n  required_providers {\n    azurerm = { source = \"hashicorp/azurerm\" }\n  }\n}\n",
		"variables.tf": "variable \"name\" {\n  type = string\n  validation {\n    condition = true\n  }\n}\n" +
			"variable \"region\" {\n  default = \"x\"\n}\n",
	})
}

func TestGenerateSmokeTestsCommand(t *testing.T) {
	t.Parallel()

	t.Run("should write the test and count what it read when there is no test yet", func(t *testing.T) {
		t.Parallel()
		// given
		repository := module()

		// when
		result, err := commands.NewGenerateSmokeTestsCommand(repository).Execute(false)

		// then
		require.NoError(t, err)
		assert.Equal(t, commands.Result{Providers: 1, Variables: 2, Validations: 1}, result)
		assert.Contains(t, repository.Smoke, `run "validation_rejects_invalid_name"`)
	})

	t.Run("should leave a hand-written test alone when not forced", func(t *testing.T) {
		t.Parallel()
		// given
		repository := module()
		repository.Smoke, repository.HasTest = "# Hand-written\n", true

		// when
		result, err := commands.NewGenerateSmokeTestsCommand(repository).Execute(false)

		// then
		require.NoError(t, err)
		assert.True(t, result.Skipped)
		assert.Zero(t, repository.Written)
	})

	t.Run("should regenerate a test that carries the marker on line 1", func(t *testing.T) {
		t.Parallel()
		// given
		repository := module()
		repository.Smoke, repository.HasTest = entities.Marker+"\nstale\n", true

		// when
		result, err := commands.NewGenerateSmokeTestsCommand(repository).Execute(false)

		// then
		require.NoError(t, err)
		assert.False(t, result.Skipped)
		assert.Equal(t, 1, repository.Written)
	})

	t.Run("should overwrite a hand-written test when forced", func(t *testing.T) {
		t.Parallel()
		// given
		repository := module()
		repository.Smoke, repository.HasTest = "# Hand-written\n", true

		// when
		_, err := commands.NewGenerateSmokeTestsCommand(repository).Execute(true)

		// then
		require.NoError(t, err)
		assert.Equal(t, 1, repository.Written)
	})
}
