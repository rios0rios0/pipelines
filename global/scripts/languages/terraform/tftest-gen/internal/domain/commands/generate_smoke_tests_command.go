// Package commands holds what the smoke-test generator does to a module.
package commands

import (
	"strings"

	"github.com/rios0rios0/pipelines/global/scripts/languages/terraform/internal/text"
	"github.com/rios0rios0/pipelines/global/scripts/languages/terraform/tftest-gen/internal/domain/entities"
	"github.com/rios0rios0/pipelines/global/scripts/languages/terraform/tftest-gen/internal/domain/repositories"
)

// Result is what a run did.
type Result struct {
	// Skipped is a hand-written test left alone.
	Skipped     bool
	Providers   int
	Variables   int
	Validations int
}

// GenerateSmokeTestsCommand writes a module's plan-time smoke test.
type GenerateSmokeTestsCommand struct {
	repository repositories.ModuleRepository
}

// NewGenerateSmokeTestsCommand wires the command to a module.
func NewGenerateSmokeTestsCommand(repository repositories.ModuleRepository) *GenerateSmokeTestsCommand {
	return &GenerateSmokeTestsCommand{repository: repository}
}

// Execute generates the test from `variables.tf` and the `required_providers`
// of `providers.tf` and `main.tf`, unless a test exists whose line 1 is not
// the marker -- a hand-written one, which only `force` overwrites.
func (c *GenerateSmokeTestsCommand) Execute(force bool) (Result, error) {
	if !force {
		existing, found, err := c.repository.SmokeTest()
		if err != nil {
			return Result{}, err
		}
		if found && !strings.Contains(text.FirstLine(existing), entities.Marker) {
			return Result{Skipped: true}, nil
		}
	}
	sources := map[string]string{}
	for _, name := range []string{"variables.tf", "main.tf", "providers.tf"} {
		source, err := c.repository.Source(name)
		if err != nil {
			return Result{}, err
		}
		sources[name] = source
	}
	providers := entities.ParseRequiredProviders(sources["providers.tf"] + "\n" + sources["main.tf"])
	variables := entities.ParseVariables(sources["variables.tf"])
	content := entities.RenderSmoke(providers, variables, entities.NewStubber())
	if err := c.repository.WriteSmokeTest(content); err != nil {
		return Result{}, err
	}
	result := Result{Providers: len(providers), Variables: len(variables)}
	for _, variable := range variables {
		if variable.Validation {
			result.Validations++
		}
	}
	return result, nil
}
