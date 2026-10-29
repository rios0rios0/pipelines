package yamldoc_test

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/rios0rios0/pipelines/internal/testsuites/yamldoc"
)

func parse(t *testing.T, text string) *yamldoc.Node {
	t.Helper()
	document, err := yamldoc.Parse([]byte(text), yamldoc.Options{})
	require.NoError(t, err)
	return document
}

func keys(node *yamldoc.Node) []string {
	var names []string
	for _, pair := range node.Pairs() {
		names = append(names, pair.Key.Str())
	}
	return names
}

func TestParse(t *testing.T) {
	t.Parallel()

	t.Run("should keep every mapping in document order when a document is parsed", func(t *testing.T) {
		t.Parallel()
		// given
		text := "zebra: 1\napple: 2\nmango: {second: b, first: a}\n"

		// when
		document := parse(t, text)

		// then
		assert.Equal(t, []string{"zebra", "apple", "mango"}, keys(document))
		assert.Equal(t, []string{"second", "first"}, keys(document.Get("mango")))
	})

	t.Run("should read `on` as a string key when a workflow declares its triggers", func(t *testing.T) {
		t.Parallel()
		// given
		text := "on:\n  workflow_call: {}\n"

		// when
		document := parse(t, text)

		// then
		assert.True(t, document.Has("on"))
		assert.Equal(t, yamldoc.Mapping, document.Get("on").Get("workflow_call").Kind())
	})

	t.Run("should resolve scalars by the core schema when values are plain", func(t *testing.T) {
		t.Parallel()
		// given
		text := "nothing: ~\nflag: true\ncount: 0x1F\nratio: 1.5\nword: yes\nquoted: '7'\ndate: 2026-01-01\n"

		// when
		document := parse(t, text)

		// then
		assert.Equal(t, yamldoc.Null, document.Get("nothing").Kind())
		assert.True(t, document.Get("flag").IsTrue())
		assert.Equal(t, "31", document.Get("count").Str())
		assert.Equal(t, "1.5", document.Get("ratio").Str())
		assert.True(t, document.Get("word").Is("yes"))
		assert.True(t, document.Get("quoted").Is("7"))
		assert.True(t, document.Get("date").Is("2026-01-01"))
	})

	t.Run("should read a document holding nothing as null when the file is empty", func(t *testing.T) {
		t.Parallel()
		// given
		text := "# only a comment\n"

		// when
		document := parse(t, text)

		// then
		assert.Equal(t, yamldoc.Null, document.Kind())
		assert.False(t, document.Truthy())
	})

	t.Run("should resolve an alias to its anchor when a value refers to one", func(t *testing.T) {
		t.Parallel()
		// given
		text := "base: &shared {path: x}\ncopy: *shared\n"

		// when
		document := parse(t, text)

		// then
		assert.True(t, document.Get("copy").Get("path").Is("x"))
	})

	t.Run("should keep application tags out when they are not accepted", func(t *testing.T) {
		t.Parallel()
		// given
		text := "url: !Sub 'https://${Api}'\n"

		// when
		_, err := yamldoc.Parse([]byte(text), yamldoc.Options{})

		// then
		require.ErrorContains(t, err, "could not determine a constructor for the tag '!Sub'")
	})

	t.Run("should read an application tag as its value when application tags are accepted", func(t *testing.T) {
		t.Parallel()
		// given
		text := "url: !Sub 'https://${Api}'\nlist: !GetAtt [Function, Arn]\n"

		// when
		document, err := yamldoc.Parse([]byte(text), yamldoc.Options{ApplicationTags: true})

		// then
		require.NoError(t, err)
		assert.True(t, document.Get("url").Is("https://${Api}"))
		assert.Len(t, document.Get("list").Items(), 2)
	})
}

func TestParseRefusals(t *testing.T) {
	t.Parallel()

	cases := map[string]struct {
		text     string
		expected string
	}{
		"should refuse a mapping key defined twice when a mapping repeats one": {
			text: "steps: []\nname: a\nsteps: [x]\n", expected: "line 3: mapping key 'steps' already defined at line 1",
		},
		"should refuse a merge key when a mapping uses one": {
			text: "base: &b {a: 1}\nother:\n  <<: *b\n", expected: "merge keys (`<<`) are not supported",
		},
		"should refuse a second document when the stream holds two": {
			text: "a: 1\n---\nb: 2\n", expected: "expected a single document in the stream",
		},
		"should refuse a core-schema tag it cannot read when one is written": {
			text: "set: !!set {a: null}\n", expected: "could not determine a constructor for the tag '!!set'",
		},
		"should refuse an anchor that contains an alias to itself when one recurses": {
			text: "loop: &self [*self]\n", expected: "contains an alias to itself",
		},
		"should report the syntax error when the YAML is malformed": {
			text: "steps: [unclosed\n", expected: "did not find expected",
		},
	}
	for name, scenario := range cases {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			// given
			data := []byte(scenario.text)

			// when
			_, err := yamldoc.Parse(data, yamldoc.Options{})

			// then
			require.ErrorContains(t, err, scenario.expected)
		})
	}
}

func TestLoad(t *testing.T) {
	t.Parallel()

	t.Run("should parse the file when it exists", func(t *testing.T) {
		t.Parallel()
		// given
		path := filepath.Join(t.TempDir(), "action.yaml")
		require.NoError(t, os.WriteFile(path, []byte("runs:\n  using: composite\n"), 0o600))

		// when
		document, err := yamldoc.Load(path, yamldoc.Options{})

		// then
		require.NoError(t, err)
		assert.True(t, document.Get("runs").Get("using").Is("composite"))
	})

	t.Run("should fail when the file does not exist", func(t *testing.T) {
		t.Parallel()
		// given
		path := filepath.Join(t.TempDir(), "missing.yaml")

		// when
		_, err := yamldoc.Load(path, yamldoc.Options{})

		// then
		require.ErrorIs(t, err, os.ErrNotExist)
	})
}
