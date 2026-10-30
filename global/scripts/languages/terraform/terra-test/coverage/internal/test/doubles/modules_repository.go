// Package doubles holds handwritten test doubles for the coverage report's
// port. No mocking library: the double implements the port the way a test
// needs a module tree to behave.
package doubles

import (
	"maps"
	"slices"

	"github.com/rios0rios0/pipelines/global/scripts/languages/terraform/terra-test/coverage/internal/domain/repositories"
)

// InMemoryModule is one module: its sources, its tests, and the warnings
// reading them produced.
type InMemoryModule struct {
	Sources  []repositories.Source
	Tests    []string
	Warnings []string
}

// InMemoryModulesRepository is a module tree held in a map of module name to
// module.
type InMemoryModulesRepository struct {
	modules map[string]InMemoryModule
}

// NewInMemoryModulesRepository holds `modules`.
func NewInMemoryModulesRepository(modules map[string]InMemoryModule) *InMemoryModulesRepository {
	return &InMemoryModulesRepository{modules: maps.Clone(modules)}
}

// Modules are the modules held, by name.
func (r *InMemoryModulesRepository) Modules() []string {
	return slices.Sorted(maps.Keys(r.modules))
}

// Sources are a module's sources and their warnings.
func (r *InMemoryModulesRepository) Sources(module string) ([]repositories.Source, []string) {
	return r.modules[module].Sources, r.modules[module].Warnings
}

// Tests are a module's tests; it has tests when any is held.
func (r *InMemoryModulesRepository) Tests(module string) ([]string, []string, bool) {
	return r.modules[module].Tests, nil, len(r.modules[module].Tests) > 0
}
