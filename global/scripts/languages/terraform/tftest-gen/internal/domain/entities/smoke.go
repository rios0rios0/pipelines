package entities

import (
	"strings"
)

// Marker is line 1 of every generated test. Its absence is what marks a
// test as hand-written, which the generator never overwrites unless forced.
const Marker = "# smoke.tftest.hcl -- auto-generated minimal plan-time smoke test."

// smokeHeader opens the generated test, after the marker.
const smokeHeader = `#
# Asserts the module parses, type-checks, and plans with mocked providers.
# Every ` + "`variable { validation { ... } }`" + ` block gets a sibling test
# that supplies a known-invalid value and asserts the validation fires,
# so the guards are covered -- not just declared.
`

// smokeRun is the plan-time run, around its variables block.
const (
	smokeRunOpen = `run "smoke_plans_successfully" {
  # given
  command = plan
`
	smokeRunClose = `
  # when
  # (the plan command above is the act under test)

  # then
  # No assertions -- if ` + "`terraform test`" + ` reaches here without a plan error,
  # the module compiled, resolved every reference, and produced a valid
  # plan graph. That is the smoke-test signal.
}
`
)

// RenderSmoke writes `tests/smoke.tftest.hcl`: a mock for every required
// provider, one plan-time run with a type-valid stub for every required
// variable, and one run per required, validated variable that hands it an
// invalid value and expects its validation to fail.
func RenderSmoke(providers []Provider, variables []Variable, stubber *Stubber) string {
	var b strings.Builder
	b.WriteString(Marker + "\n" + smokeHeader)
	if len(providers) > 0 {
		b.WriteString("\n")
		for _, provider := range providers {
			b.WriteString(`mock_provider "` + provider.Local + "\" {}\n")
		}
	}
	b.WriteString("\n" + smokeRunOpen)

	var required []Variable
	valid := map[string]string{}
	for _, variable := range variables {
		if !variable.Required {
			continue
		}
		required = append(required, variable)
		stub, err := stubber.Valid(variable.Type, variable.Name)
		if err != nil {
			stub = fallbackStub
		}
		valid[variable.Name] = stub
	}
	if len(required) > 0 {
		b.WriteString("\n  variables {\n")
		for _, variable := range required {
			b.WriteString("    " + variable.Name + " = " + valid[variable.Name] + "\n")
		}
		b.WriteString("  }\n")
	}
	b.WriteString(smokeRunClose)

	var runs []string
	for _, variable := range required {
		if !variable.Validation {
			continue
		}
		invalid, ok := Invalid(variable)
		if !ok {
			// No reliable type-valid-but-value-invalid stub for this type
			// (object / tuple / bool): its test is left to be hand-written.
			continue
		}
		runs = append(runs, validationRun(variable.Name, invalid, required, valid))
	}
	if len(runs) > 0 {
		b.WriteString(strings.Join(runs, "\n") + "\n")
	}
	return b.String()
}

// validationRun is the run proving `name`'s validation rejects `invalid`,
// every other required variable given its valid stub.
func validationRun(name, invalid string, required []Variable, valid map[string]string) string {
	lines := []string{"  variables {"}
	for _, other := range required {
		value := valid[other.Name]
		if other.Name == name {
			value = invalid
		}
		lines = append(lines, "    "+other.Name+" = "+value)
	}
	lines = append(lines, "  }")
	return "\nrun \"validation_rejects_invalid_" + name + "\" {\n" +
		"  # given\n" +
		"  command = plan\n\n" +
		strings.Join(lines, "\n") + "\n\n" +
		"  # when\n" +
		"  # (plan is executed with var." + name + " set to an invalid value)\n\n" +
		"  # then\n" +
		"  # The validation block on var." + name + " must reject the\n" +
		"  # invalid value -- expect_failures asserts the plan errors\n" +
		"  # out on exactly that variable. Proves the guard fires, not\n" +
		"  # just that it's declared.\n" +
		"  expect_failures = [\n" +
		"    var." + name + ",\n" +
		"  ]\n" +
		"}"
}
