// Package doubles holds handwritten test doubles for the smoke-test
// generator's ports. No mocking library: each double implements a port the
// way a test needs it to behave.
package doubles

import "maps"

// InMemoryModuleRepository is a module held in a map of root file to text,
// and the test written to it.
type InMemoryModuleRepository struct {
	Files   map[string]string
	Smoke   string
	HasTest bool
	Written int
}

// NewInMemoryModuleRepository holds `files` and no test.
func NewInMemoryModuleRepository(files map[string]string) *InMemoryModuleRepository {
	return &InMemoryModuleRepository{Files: maps.Clone(files)}
}

// Source is a root file's text, empty when absent.
func (r *InMemoryModuleRepository) Source(name string) (string, error) {
	return r.Files[name], nil
}

// SmokeTest is the test held, if any.
func (r *InMemoryModuleRepository) SmokeTest() (string, bool, error) {
	return r.Smoke, r.HasTest, nil
}

// WriteSmokeTest holds the test and counts the write.
func (r *InMemoryModuleRepository) WriteSmokeTest(content string) error {
	r.Smoke, r.HasTest = content, true
	r.Written++
	return nil
}

// SmokeTestPath is a fixed name.
func (r *InMemoryModuleRepository) SmokeTestPath() string {
	return "/module/tests/smoke.tftest.hcl"
}

// StubFormatter answers every format with a canned warning, and counts calls.
type StubFormatter struct {
	Warning string
	Calls   int
}

// Format returns the canned warning.
func (f *StubFormatter) Format() string {
	f.Calls++
	return f.Warning
}
