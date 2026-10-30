package entities_test

import (
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"

	"github.com/rios0rios0/pipelines/global/scripts/languages/terraform/terra-test/coverage/internal/domain/entities"
)

func TestMask(t *testing.T) {
	t.Parallel()

	t.Run("should blank comments and string bodies but keep offsets and line breaks", func(t *testing.T) {
		t.Parallel()
		// given
		source := "a = \"aws_x.y\" # aws_x.z\n/* {\n} */ b = 1 // c"

		// when
		masked := entities.Mask(source)

		// then
		assert.Len(t, masked, len(source))
		assert.Equal(t, strings.Count(source, "\n"), strings.Count(masked, "\n"))
		assert.Equal(t, "a = \"       \"          \n    \n     b = 1     ", masked)
	})

	t.Run("should keep an interpolation as code when a quote sits inside it", func(t *testing.T) {
		t.Parallel()
		// given
		source := `v = "${join(",", [aws_x.y.id])}"`

		// when
		masked := entities.Mask(source)

		// then
		assert.Contains(t, masked, `join(",", [aws_x.y.id])`)
		assert.NotContains(t, masked, "${")
	})

	t.Run("should turn a heredoc into one bracketed value keeping its interpolations", func(t *testing.T) {
		t.Parallel()
		// given
		source := "p = <<-EOT\n  { \"r\": \"${aws_x.y.arn}\" } aws_x.z\n  EOT\nq = 1"

		// when
		masked := entities.Mask(source)

		// then
		assert.True(t, strings.HasPrefix(masked, "p = ("))
		assert.Contains(t, masked, "aws_x.y.arn")
		assert.NotContains(t, masked, "aws_x.z")
		assert.Contains(t, masked, ")\nq = 1")
	})
}

func TestTraversals(t *testing.T) {
	t.Parallel()

	t.Run("should read every reference form and stop each name at the first non-name character", func(t *testing.T) {
		t.Parallel()
		// given
		expression := "local.a + var.b + data.aws_ami.this.id + module.m.x + check.c + output.o + " +
			"aws_rds_cluster_instance.main[0].id"

		// when
		found := entities.Traversals(expression)

		// then
		assert.Equal(t, map[string]bool{
			"local.a": true, "var.b": true, "data.aws_ami.this": true, "module.m": true,
			"check.c": true, "output.o": true, "aws_rds_cluster_instance.main": true,
		}, found)
	})

	t.Run("should not read a reference inside a longer chain, a word, or without an underscore", func(t *testing.T) {
		t.Parallel()
		// given
		expression := "x.aws_s3_bucket.y + myvar.z + each.value + self.id + p.name + évar.q + aws_.x"

		// when
		found := entities.Traversals(expression)

		// then
		assert.Empty(t, found)
	})
}
