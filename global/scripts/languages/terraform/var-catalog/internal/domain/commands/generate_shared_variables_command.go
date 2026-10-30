// Package commands holds what the shared-variable generator does to a
// repository.
package commands

import (
	"github.com/rios0rios0/pipelines/global/scripts/languages/terraform/var-catalog/internal/domain/entities"
	"github.com/rios0rios0/pipelines/global/scripts/languages/terraform/var-catalog/internal/domain/repositories"
)

// Mode is what a run may do to the repository.
type Mode int

const (
	// ModeWrite rewrites every generated file that is out of date.
	ModeWrite Mode = iota
	// ModeCheck writes nothing; out-of-date files are the CI gate's failure.
	ModeCheck
	// ModeReport writes nothing and fails nothing.
	ModeReport
)

// Result is what a run found and did.
type Result struct {
	// NoCatalog is a repository with no catalog, or one with no entries.
	NoCatalog bool
	// Drift are the generated files, relative to the root, whose committed
	// contents differ from what the catalog generates.
	Drift []string
	// Preserved are the `<stack>: <name>` declarations left hand-written.
	Preserved []string
	// Written is how many files were rewritten or removed.
	Written int
}

// GenerateSharedVariablesCommand keeps each stack's generated declarations in
// step with the catalog.
type GenerateSharedVariablesCommand struct {
	repository repositories.StacksRepository
}

// NewGenerateSharedVariablesCommand wires the command to a repository.
func NewGenerateSharedVariablesCommand(repository repositories.StacksRepository) *GenerateSharedVariablesCommand {
	return &GenerateSharedVariablesCommand{repository: repository}
}

// Execute compares every stack's generated file with what the catalog
// generates for it and, in ModeWrite, rewrites the ones that differ -- removing
// one whose stack no longer uses anything catalogued.
func (c *GenerateSharedVariablesCommand) Execute(mode Mode) (Result, error) {
	source, found, err := c.repository.Catalog()
	if err != nil {
		return Result{}, err
	}
	catalog := entities.Catalog{}
	if found {
		catalog = entities.ParseCatalog(source)
	}
	if len(catalog) == 0 {
		return Result{NoCatalog: true}, nil
	}
	var result Result
	for _, stack := range c.repository.Stacks() {
		if err = c.reconcile(stack, catalog, mode, &result); err != nil {
			return result, err
		}
	}
	return result, nil
}

// reconcile brings one stack's generated file in step, as far as `mode` allows.
func (c *GenerateSharedVariablesCommand) reconcile(
	stack string, catalog entities.Catalog, mode Mode, result *Result,
) error {
	sources, err := c.repository.Sources(stack)
	if err != nil {
		return err
	}
	plan := entities.PlanStack(sources, catalog)
	for _, name := range plan.Preserved {
		result.Preserved = append(result.Preserved, stack+": "+name)
	}
	want := entities.Render(plan.Generate, catalog)
	have, err := c.repository.Generated(stack)
	if err != nil {
		return err
	}
	if want == have {
		return nil
	}
	result.Drift = append(result.Drift, stack+"/"+entities.OutputName)
	if mode != ModeWrite {
		return nil
	}
	if want != "" {
		err = c.repository.WriteGenerated(stack, want)
	} else {
		err = c.repository.RemoveGenerated(stack)
	}
	if err != nil {
		return err
	}
	result.Written++
	return nil
}
