package entities_test

import (
	"testing"

	"github.com/stretchr/testify/assert"

	"github.com/rios0rios0/pipelines/global/scripts/languages/terraform/var-catalog/internal/domain/entities"
)

const twoEntries = `locals {
  declarations = {
    environment = <<-EOT
      variable "environment" {
        type = string
      }
    EOT

    tags = <<-EOT
      variable "tags" {
        type = map(string)
      }
    EOT
  }
}
`

func TestParseCatalog(t *testing.T) {
	t.Parallel()

	t.Run("should read every entry dedented to column 0 when the catalog is well formed", func(t *testing.T) {
		t.Parallel()
		// given
		source := twoEntries

		// when
		catalog := entities.ParseCatalog(source)

		// then
		assert.Equal(t, entities.Catalog{
			"environment": "variable \"environment\" {\n  type = string\n}",
			"tags":        "variable \"tags\" {\n  type = map(string)\n}",
		}, catalog)
	})

	t.Run("should not end an entry at a line that only starts with its tag", func(t *testing.T) {
		t.Parallel()
		// given
		source := "x = <<EOT\n  EOTX is not the end\n  EOT  \n"

		// when
		catalog := entities.ParseCatalog(source)

		// then
		assert.Equal(t, entities.Catalog{"x": "EOTX is not the end"}, catalog)
	})

	t.Run("should drop blank lines after the opener and keep the last of two entries for one name", func(t *testing.T) {
		t.Parallel()
		// given
		source := "a = <<-EOT\n\n\n  first\nEOT\na = <<-EOT\n  second\nEOT\n"

		// when
		catalog := entities.ParseCatalog(source)

		// then
		assert.Equal(t, entities.Catalog{"a": "second"}, catalog)
	})

	t.Run("should skip an entry whose heredoc never ends", func(t *testing.T) {
		t.Parallel()
		// given
		source := "a = <<-EOT\n  variable \"a\" {}\n"

		// when
		catalog := entities.ParseCatalog(source)

		// then
		assert.Empty(t, catalog)
	})
}

func TestDedent(t *testing.T) {
	t.Parallel()

	t.Run("should strip the shared indentation counted in characters and empty blank lines", func(t *testing.T) {
		t.Parallel()
		// given
		block := "\u00a0 a\n   \n\u00a0  b"

		// when
		dedented := entities.Dedent(block)

		// then
		assert.Equal(t, "a\n\n b", dedented)
	})
}
