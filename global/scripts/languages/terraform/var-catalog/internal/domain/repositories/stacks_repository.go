// Package repositories holds the ports the shared-variable generator reads a
// repository through and writes its generated files through.
package repositories

// StacksRepository is a Terragrunt repository as the generator sees it: a
// catalog at its root, and the root modules under `stacks/`.
type StacksRepository interface {
	// Root is the repository, as reports name it.
	Root() string
	// Catalog is the catalog's text, and false when the repository has none.
	Catalog() (string, bool, error)
	// Stacks are every directory under `stacks/` holding a `.tf` file, in
	// path order, relative to the root: a root module is a directory
	// Terraform can be pointed at, whatever its entry file is called.
	Stacks() []string
	// Sources are the texts of a stack's own `.tf` files, the generated one
	// left out, in path order.
	Sources(stack string) ([]string, error)
	// Generated is a stack's generated file as committed, empty when absent.
	Generated(stack string) (string, error)
	// WriteGenerated replaces a stack's generated file.
	WriteGenerated(stack, content string) error
	// RemoveGenerated deletes a stack's generated file, if it has one.
	RemoveGenerated(stack string) error
}
