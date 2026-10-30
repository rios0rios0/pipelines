// Package repositories holds the port the coverage report reads a module
// tree through.
package repositories

// Source is one file a module consists of.
type Source struct {
	// Path is the file relative to the repository, with forward slashes.
	Path string
	// Namespace is the file's directory relative to its module, `.` for the
	// module root.
	Namespace string
	// Text is the file's contents.
	Text string
}

// ModulesRepository is a repository as the coverage report sees it: modules,
// each with its own `.tf` files and the `tests/*.tftest.hcl` that `terraform
// test` runs for it.
type ModulesRepository interface {
	// Modules are the module directories, in path order.
	Modules() []string
	// Sources are a module's `.tf` files, the test code, vendored copies and
	// examples left out, in path order; and a warning for each file that could
	// not be read, which is skipped rather than failing the report.
	Sources(module string) ([]Source, []string)
	// Tests are the texts of the module's `tests/*.tftest.hcl`, in path
	// order, with a warning for each that could not be read; and whether it
	// has any test file at all.
	Tests(module string) ([]string, []string, bool)
}
