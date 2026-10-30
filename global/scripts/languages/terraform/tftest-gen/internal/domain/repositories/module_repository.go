// Package repositories holds the ports the smoke-test generator reads a
// module through, writes its test through, and formats the test with.
package repositories

// ModuleRepository is a single-module repository: the repository root IS the
// module, and its test lives at `tests/smoke.tftest.hcl`.
type ModuleRepository interface {
	// Source is a root file's text, empty when it does not exist.
	Source(name string) (string, error)
	// SmokeTest is the existing test's text, and false when there is none.
	SmokeTest() (string, bool, error)
	// WriteSmokeTest writes the test, creating `tests/` if needed.
	WriteSmokeTest(content string) error
	// SmokeTestPath is where the test lives, as messages name it.
	SmokeTestPath() string
}

// Formatter canonicalises the generated test's formatting.
type Formatter interface {
	// Format formats the module's `tests/`, and says why when it could not:
	// formatting is a nicety, never a reason to fail the generation.
	Format() (warning string)
}
