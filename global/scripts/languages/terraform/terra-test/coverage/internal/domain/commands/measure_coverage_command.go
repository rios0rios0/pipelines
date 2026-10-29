// Package commands holds what the coverage report does to a module tree.
package commands

import (
	"github.com/rios0rios0/pipelines/global/scripts/languages/terraform/terra-test/coverage/internal/domain/entities"
	"github.com/rios0rios0/pipelines/global/scripts/languages/terraform/terra-test/coverage/internal/domain/repositories"
)

// Result is the measurement: per-line coverage, the block counts, and a
// warning per file that could not be read.
type Result struct {
	Coverage entities.Coverage
	Total    int
	Covered  int
	Warnings []string
}

// MeasureCoverageCommand measures which declared blocks an executed
// assertion reaches.
type MeasureCoverageCommand struct {
	repository repositories.ModulesRepository
}

// NewMeasureCoverageCommand wires the command to a repository.
func NewMeasureCoverageCommand(repository repositories.ModulesRepository) *MeasureCoverageCommand {
	return &MeasureCoverageCommand{repository: repository}
}

// Execute scans every module: its blocks are the denominator, and a block is
// covered when the closure of what its tests assert reaches it.
func (c *MeasureCoverageCommand) Execute() Result {
	result := Result{Coverage: entities.Coverage{}}
	for _, module := range c.repository.Modules() {
		scan := entities.NewModuleScan()
		tests, testWarnings, hasTests := c.repository.Tests(module)
		sources, sourceWarnings := c.repository.Sources(module)
		result.Warnings = append(result.Warnings, sourceWarnings...)
		result.Warnings = append(result.Warnings, testWarnings...)
		for _, source := range sources {
			scan.ScanDeclarations(source.Text, source.Path, source.Namespace, hasTests)
		}
		for _, test := range tests {
			scan.ScanTestFile(test)
		}
		reachable := scan.Reachable()
		for _, declared := range scan.Declared {
			covered := reachable[declared.Address]
			result.Total++
			if covered {
				result.Covered++
			}
			result.Coverage.Mark(declared.Path, declared.Line, covered)
		}
	}
	return result
}
