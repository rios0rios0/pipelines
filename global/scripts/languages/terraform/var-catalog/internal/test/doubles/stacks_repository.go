// Package doubles holds handwritten test doubles for the shared-variable
// generator's port. No mocking library: the double implements the port the
// way a test needs a repository to behave.
package doubles

import (
	"errors"
	"maps"
	"slices"
)

// ErrUnreadable is what a source the double was told to fail on returns.
var ErrUnreadable = errors.New("unreadable")

// InMemoryStacksRepository is a repository held in maps: each stack's source
// texts and generated file, and the catalog.
type InMemoryStacksRepository struct {
	CatalogText string
	HasCatalog  bool
	StackFiles  map[string][]string
	Files       map[string]string
	Unreadable  string
	Writes      []string
	Removals    []string
}

// NewInMemoryStacksRepository holds `catalog` and the stacks' sources.
func NewInMemoryStacksRepository(catalog string, stacks map[string][]string) *InMemoryStacksRepository {
	return &InMemoryStacksRepository{
		CatalogText: catalog,
		HasCatalog:  catalog != "",
		StackFiles:  maps.Clone(stacks),
		Files:       map[string]string{},
	}
}

// Root is a fixed name.
func (r *InMemoryStacksRepository) Root() string { return "/repo" }

// Catalog is the catalog held, if any.
func (r *InMemoryStacksRepository) Catalog() (string, bool, error) {
	return r.CatalogText, r.HasCatalog, nil
}

// Stacks are the stacks held, by name.
func (r *InMemoryStacksRepository) Stacks() []string {
	return slices.Sorted(maps.Keys(r.StackFiles))
}

// Sources are a stack's sources, or an error for the stack marked unreadable.
func (r *InMemoryStacksRepository) Sources(stack string) ([]string, error) {
	if stack == r.Unreadable {
		return nil, ErrUnreadable
	}
	return r.StackFiles[stack], nil
}

// Generated is a stack's generated file as held.
func (r *InMemoryStacksRepository) Generated(stack string) (string, error) {
	return r.Files[stack], nil
}

// WriteGenerated records and holds a write.
func (r *InMemoryStacksRepository) WriteGenerated(stack, content string) error {
	r.Writes = append(r.Writes, stack)
	r.Files[stack] = content
	return nil
}

// RemoveGenerated records and applies a removal.
func (r *InMemoryStacksRepository) RemoveGenerated(stack string) error {
	r.Removals = append(r.Removals, stack)
	delete(r.Files, stack)
	return nil
}
