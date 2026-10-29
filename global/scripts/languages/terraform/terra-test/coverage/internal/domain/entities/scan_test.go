package entities_test

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/rios0rios0/pipelines/global/scripts/languages/terraform/terra-test/coverage/internal/domain/entities"
)

const module = `locals {
  bucket_id = aws_s3_bucket.logs.id
}

resource "aws_s3_bucket" "logs" {
  bucket = "l"
}

resource "aws_s3_bucket" "unused" {
  bucket = "u"
}

resource "aws_kms_key" "guarded" {
  lifecycle {
    precondition {
      condition     = var.size > 0
      error_message = "size"
    }
  }
}

output "bucket_id" {
  value = local.bucket_id
}
`

func TestScannerBlocks(t *testing.T) {
	t.Parallel()

	t.Run("should find top-level blocks with their labels and skip their bodies", func(t *testing.T) {
		t.Parallel()
		// given
		scanner := entities.NewScanner(module, entities.Mask(module))

		// when
		blocks := scanner.Blocks(0, len(module))

		// then
		require.Len(t, blocks, 5)
		assert.Equal(t, "locals", blocks[0].Kind)
		assert.Equal(t, []string{"aws_s3_bucket", "logs"}, blocks[1].Labels)
		assert.Equal(t, "output", blocks[4].Kind)
	})
}

func TestScannerExpression(t *testing.T) {
	t.Parallel()

	t.Run("should read an attribute and refuse a comparison as an assignment", func(t *testing.T) {
		t.Parallel()
		// given
		source := "a == b\nvalue = [x,\n  y]\n"
		scanner := entities.NewScanner(source, entities.Mask(source))

		// when
		value, found := scanner.Expression(0, len(source), "value")
		_, comparison := scanner.Expression(0, len(source), "a")

		// then
		assert.True(t, found)
		assert.Equal(t, "[x,\n  y]", value)
		assert.False(t, comparison)
	})
}

func TestModuleScan(t *testing.T) {
	t.Parallel()

	t.Run("should cover what an asserted output reaches through a local and a guarded block", func(t *testing.T) {
		t.Parallel()
		// given
		scan := entities.NewModuleScan()
		scan.ScanDeclarations(module, "main.tf", entities.RootNamespace, true)
		scan.ScanTestFile("run \"r\" {\n  assert {\n    condition = output.bucket_id != \"\"\n  }\n}\n")

		// when
		reachable := scan.Reachable()

		// then
		covered := map[int]bool{}
		for _, declared := range scan.Declared {
			covered[declared.Line] = reachable[declared.Address]
		}
		assert.Equal(t, map[int]bool{5: true, 9: false, 13: true, 22: true}, covered)
	})

	t.Run("should seed what an expect_failures list names, entry by entry", func(t *testing.T) {
		t.Parallel()
		// given
		scan := entities.NewModuleScan()

		// when
		scan.ScanTestFile("run \"r\" {\n  expect_failures = [\n    var.size,\n    aws_s3_bucket.logs,\n  ]\n}\n")

		// then
		assert.Equal(t, map[string]bool{"var.size@.": true, "aws_s3_bucket.logs@.": true}, scan.Seeds)
	})

	t.Run("should keep the same address in two directories apart", func(t *testing.T) {
		t.Parallel()
		// given
		scan := entities.NewModuleScan()
		scan.ScanDeclarations("resource \"aws_s3_bucket\" \"this\" {}\n", "a/main.tf", "a", false)
		scan.ScanDeclarations("resource \"aws_s3_bucket\" \"this\" {}\n", "b/main.tf", "b", false)

		// when
		addresses := []string{scan.Declared[0].Address, scan.Declared[1].Address}

		// then
		assert.Equal(t, []string{"aws_s3_bucket.this@a", "aws_s3_bucket.this@b"}, addresses)
	})
}

func TestRender(t *testing.T) {
	t.Parallel()

	t.Run("should list files in path order and lines ascending, covered winning on a shared line", func(t *testing.T) {
		t.Parallel()
		// given
		coverage := entities.Coverage{}
		coverage.Mark("z.tf", 4, false)
		coverage.Mark("a&b.tf", 9, false)
		coverage.Mark("a&b.tf", 2, false)
		coverage.Mark("a&b.tf", 2, true)

		// when
		report := entities.Render(coverage)

		// then
		assert.Contains(t, report, "<coverage version=\"1\">\n  <file path=\"a&amp;b.tf\">\n"+
			"    <lineToCover lineNumber=\"2\" covered=\"true\"/>\n    <lineToCover lineNumber=\"9\" covered=\"false\"/>\n"+
			"  </file>\n  <file path=\"z.tf\">\n")
		assert.Contains(t, report, "CAVEAT, BLOCK GRANULARITY")
	})

	t.Run("should still be a valid document when nothing was measured", func(t *testing.T) {
		t.Parallel()
		// given
		coverage := entities.Coverage{}

		// when
		report := entities.Render(coverage)

		// then
		assert.Contains(t, report, "-->\n<coverage version=\"1\"/>\n")
	})
}
