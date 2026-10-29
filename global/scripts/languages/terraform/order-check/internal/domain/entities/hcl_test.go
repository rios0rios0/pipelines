package entities_test

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/rios0rios0/pipelines/global/scripts/languages/terraform/order-check/internal/domain/entities"
)

func TestTopLevelBlocks(t *testing.T) {
	t.Parallel()

	t.Run("should ignore braces inside heredocs, comments and strings when finding a block's end", func(t *testing.T) {
		t.Parallel()
		// given
		source := "variable \"a\" {\n  /* { */\n  default = <<-EOT\n    } stray\n  EOT\n  d = \"}\" # }\n}\n" +
			"variable \"b\" {}\n"

		// when
		blocks, err := entities.TopLevelBlocks(source, "variable")

		// then
		require.NoError(t, err)
		require.Len(t, blocks, 2)
		assert.Equal(t, "a", blocks[0].Name)
		assert.Equal(t, len(source)-len("variable \"b\" {}\n"), blocks[0].End)
	})

	t.Run("should fail when a block never closes", func(t *testing.T) {
		t.Parallel()
		// given
		source := "variable \"a\" {\n  type = string\n"

		// when
		_, err := entities.TopLevelBlocks(source, "variable")

		// then
		require.ErrorIs(t, err, entities.ErrUnbalanced)
	})
}

func TestSplitEntries(t *testing.T) {
	t.Parallel()

	t.Run("should keep a multi-line value in its entry and reproduce the body exactly", func(t *testing.T) {
		t.Parallel()
		// given
		body := "\n  tags = local.tags\n\n  kube = {\n    host = dependency.k.outputs.host\n  }\n  image = \"x\"\n"

		// when
		entries, suffix := entities.SplitEntries(body)

		// then
		require.Len(t, entries, 3)
		assert.Equal(t, []string{"tags", "kube", "image"}, []string{entries[0].Key, entries[1].Key, entries[2].Key})
		assert.Contains(t, entries[1].Value, "dependency.k.outputs.host")
		assert.Equal(t, body, entries[0].Text+entries[1].Text+entries[2].Text+suffix)
	})
}

func TestReorder(t *testing.T) {
	t.Parallel()

	t.Run("should carry the trivia between two blocks with the block after it", func(t *testing.T) {
		t.Parallel()
		// given
		source := "variable \"b\" {}\n\n# a's note\nvariable \"a\" {}\n"
		blocks, err := entities.TopLevelBlocks(source, "variable")
		require.NoError(t, err)
		rank := map[string]int{"a": 0, "b": 1}

		// when
		rewritten, ok := entities.Reorder(source, blocks[0].Start, blocks[1].End, blocks,
			func(x, y entities.Block) int { return rank[x.Name] - rank[y.Name] })

		// then
		assert.True(t, ok)
		assert.Equal(t, "\n# a's note\nvariable \"a\" {}\nvariable \"b\" {}\n", rewritten)
	})

	t.Run("should refuse a region where one block lies inside another rather than corrupt it", func(t *testing.T) {
		t.Parallel()
		// given
		// The inner `variable` sits at column 0 inside the outer block's heredoc,
		// so it is found as a block of its own that ends before the outer one.
		source := "variable \"outer\" {\n  default = <<-EOT\nvariable \"inner\" {}\n  EOT\n}\n"
		blocks, err := entities.TopLevelBlocks(source, "variable")
		require.NoError(t, err)
		require.Len(t, blocks, 2)

		// when
		_, ok := entities.Reorder(
			source,
			blocks[0].Start,
			blocks[0].End,
			blocks,
			func(_, _ entities.Block) int { return 0 },
		)

		// then
		assert.False(t, ok)
	})
}

func TestNumber(t *testing.T) {
	t.Parallel()

	t.Run("should compare layer numbers by value whatever their size or script", func(t *testing.T) {
		t.Parallel()
		// given
		small, arabic, huge := entities.ParseNumber(
			"007",
		), entities.ParseNumber(
			"\u0663",
		), entities.ParseNumber(
			"123456789012345678901",
		)

		// when
		formatted := []string{small.String(), arabic.String(), huge.String(), entities.Unmapped().String()}

		// then
		assert.Equal(t, []string{"07", "03", "123456789012345678901", "9999"}, formatted)
		assert.Negative(t, arabic.Compare(small))
		assert.Positive(t, huge.Compare(entities.Unmapped()))
	})
}

func TestParseConfig(t *testing.T) {
	t.Parallel()

	t.Run("should rank providers in the order given and ignore paths matching a glob", func(t *testing.T) {
		t.Parallel()
		// given
		data := []byte(`{"provider_order": ["random", "azurerm"], "ignore": ["modules/**"]}`)

		// when
		config, err := entities.ParseConfig(data)
		ignored, ignoreErr := config.IsIgnored("modules/foo/providers.tf")

		// then
		require.NoError(t, err)
		require.NoError(t, ignoreErr)
		assert.Equal(t, map[string]int{"random": 0, "azurerm": 1}, config.Weights)
		assert.True(t, ignored)
	})

	t.Run("should read an object's keys in the order written", func(t *testing.T) {
		t.Parallel()
		// given
		data := []byte(`{"provider_order": {"random": 9, "azurerm": 1, "random": 3}}`)

		// when
		config, err := entities.ParseConfig(data)

		// then
		require.NoError(t, err)
		assert.Equal(t, map[string]int{"random": 0, "azurerm": 1}, config.Weights)
	})

	t.Run("should refuse a ranking that is not a list and an ignore entry that is not a string", func(t *testing.T) {
		t.Parallel()
		// given
		badOrder := []byte(`{"provider_order": null}`)
		badIgnore := []byte(`{"ignore": [5]}`)

		// when
		_, orderErr := entities.ParseConfig(badOrder)
		config, err := entities.ParseConfig(badIgnore)
		_, ignoreErr := config.IsIgnored("x")

		// then
		require.ErrorIs(t, orderErr, entities.ErrConfig)
		require.NoError(t, err)
		require.ErrorIs(t, ignoreErr, entities.ErrConfig)
	})
}
