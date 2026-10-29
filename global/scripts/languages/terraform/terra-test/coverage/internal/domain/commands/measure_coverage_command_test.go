package commands_test

import (
	"testing"

	"github.com/stretchr/testify/assert"

	"github.com/rios0rios0/pipelines/global/scripts/languages/terraform/terra-test/coverage/internal/domain/commands"
	"github.com/rios0rios0/pipelines/global/scripts/languages/terraform/terra-test/coverage/internal/domain/entities"
	"github.com/rios0rios0/pipelines/global/scripts/languages/terraform/terra-test/coverage/internal/domain/repositories"
	"github.com/rios0rios0/pipelines/global/scripts/languages/terraform/terra-test/coverage/internal/test/doubles"
)

func TestMeasureCoverageCommand(t *testing.T) {
	t.Parallel()

	t.Run("should cover only the blocks a module's own tests reach", func(t *testing.T) {
		t.Parallel()
		// given
		repository := doubles.NewInMemoryModulesRepository(map[string]doubles.InMemoryModule{
			"modules/tested": {
				Sources: []repositories.Source{{
					Path:      "modules/tested/main.tf",
					Namespace: ".",
					Text:      "resource \"aws_s3_bucket\" \"a\" {}\n\nresource \"aws_s3_bucket\" \"b\" {}\n",
				}},
				Tests: []string{"run \"r\" {\n  assert {\n    condition = aws_s3_bucket.a.id != \"\"\n  }\n}\n"},
			},
			"modules/untested": {
				Sources: []repositories.Source{{
					Path: "modules/untested/main.tf", Namespace: ".", Text: "resource \"aws_s3_bucket\" \"a\" {}\n",
				}},
				Warnings: []string{"warning: cannot read x"},
			},
		})

		// when
		result := commands.NewMeasureCoverageCommand(repository).Execute()

		// then
		assert.Equal(t, 3, result.Total)
		assert.Equal(t, 1, result.Covered)
		assert.Equal(t, entities.Coverage{
			"modules/tested/main.tf":   {1: true, 3: false},
			"modules/untested/main.tf": {1: false},
		}, result.Coverage)
		assert.Equal(t, []string{"warning: cannot read x"}, result.Warnings)
	})

	t.Run("should measure nothing when there is no module", func(t *testing.T) {
		t.Parallel()
		// given
		repository := doubles.NewInMemoryModulesRepository(nil)

		// when
		result := commands.NewMeasureCoverageCommand(repository).Execute()

		// then
		assert.Zero(t, result.Total)
		assert.Empty(t, result.Coverage)
	})
}
