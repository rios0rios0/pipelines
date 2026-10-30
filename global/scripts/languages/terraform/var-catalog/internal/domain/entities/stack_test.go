package entities_test

import (
	"testing"

	"github.com/stretchr/testify/assert"

	"github.com/rios0rios0/pipelines/global/scripts/languages/terraform/var-catalog/internal/domain/entities"
)

func TestStripComments(t *testing.T) {
	t.Parallel()

	t.Run("should keep a // and a /* */ that sit inside a string", func(t *testing.T) {
		t.Parallel()
		// given
		source := "api = \"https://x/${var.a}\" # var.b\npattern = \"/* ${var.c} */\" // var.d"

		// when
		stripped := entities.StripComments(source)

		// then
		assert.Equal(t, "api = \"https://x/${var.a}\" \npattern = \"/* ${var.c} */\" ", stripped)
	})

	t.Run("should drop a block comment across lines and keep what follows it", func(t *testing.T) {
		t.Parallel()
		// given
		source := "a /* var.x\nvar.y */ var.z\n\"esc \\\" # still a string\""

		// when
		stripped := entities.StripComments(source)

		// then
		assert.Equal(t, "a \n var.z\n\"esc \\\" # still a string\"", stripped)
	})
}

func TestUsedVariables(t *testing.T) {
	t.Parallel()

	t.Run("should read the name up to the first non-name character when it follows a boundary", func(t *testing.T) {
		t.Parallel()
		// given
		source := "a = var.placement.cloud + €var.b + (var.c_1)"

		// when
		used := entities.UsedVariables(source)

		// then
		assert.Equal(t, []string{"placement", "b", "c_1"}, used)
	})

	t.Run("should not read a use inside a longer word when a letter of any script precedes it", func(t *testing.T) {
		t.Parallel()
		// given
		source := "myvar.a _var.b évar.c var.1d"

		// when
		used := entities.UsedVariables(source)

		// then
		assert.Empty(t, used)
	})
}

func TestDeclaredVariables(t *testing.T) {
	t.Parallel()

	t.Run("should read only the declarations at column 0", func(t *testing.T) {
		t.Parallel()
		// given
		source := "variable \"a\" {}\n  variable \"b\" {}\nvariable\n\"c\"\n{\n}\n"

		// when
		declared := entities.DeclaredVariables(source)

		// then
		assert.Equal(t, []string{"a", "c"}, declared)
	})
}

func TestPlanStack(t *testing.T) {
	t.Parallel()

	t.Run("should generate what a stack uses and preserve what it declares by hand", func(t *testing.T) {
		t.Parallel()
		// given
		catalog := entities.Catalog{"environment": "e", "tags": "t", "region": "r"}
		sources := []string{"x = var.tags\n# var.region\n", "y = var.environment\nvariable \"environment\" {}\n"}

		// when
		plan := entities.PlanStack(sources, catalog)

		// then
		assert.Equal(t, []string{"tags"}, plan.Generate)
		assert.Equal(t, []string{"environment"}, plan.Preserved)
	})
}

func TestRender(t *testing.T) {
	t.Parallel()

	t.Run("should write the marker and the bodies a blank line apart when names are given", func(t *testing.T) {
		t.Parallel()
		// given
		catalog := entities.Catalog{"a": "variable \"a\" {}", "b": "variable \"b\" {}"}

		// when
		rendered := entities.Render([]string{"a", "b"}, catalog)

		// then
		assert.Equal(t, entities.Marker+"\n\nvariable \"a\" {}\n\nvariable \"b\" {}\n", rendered)
	})

	t.Run("should render nothing when no name is given", func(t *testing.T) {
		t.Parallel()
		// given
		catalog := entities.Catalog{"a": "variable \"a\" {}"}

		// when
		rendered := entities.Render(nil, catalog)

		// then
		assert.Empty(t, rendered)
	})
}
