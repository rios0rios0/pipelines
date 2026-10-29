package filetext_test

import (
	"errors"
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/rios0rios0/pipelines/internal/testsuites/filetext"
)

// layout writes `files` (relative path -> content) under `root`.
func layout(t *testing.T, root string, files map[string]string) {
	t.Helper()
	for name, content := range files {
		path := filepath.Join(root, filepath.FromSlash(name))
		require.NoError(t, os.MkdirAll(filepath.Dir(path), 0o750))
		require.NoError(t, os.WriteFile(path, []byte(content), 0o600))
	}
}

// walked lists what Walk visits under root, relative to it.
func walked(t *testing.T, root string, skip func(string) bool) []string {
	t.Helper()
	var visited []string
	err := filetext.Walk(root, skip, func(path string) error {
		relative, err := filepath.Rel(root, path)
		require.NoError(t, err)
		visited = append(visited, filepath.ToSlash(relative))
		return nil
	})
	require.NoError(t, err)
	return visited
}

func TestWalk(t *testing.T) {
	t.Parallel()

	t.Run("should visit a directory's files before its subdirectories when it walks a tree", func(t *testing.T) {
		t.Parallel()
		// given
		root := t.TempDir()
		layout(t, root, map[string]string{"b.yaml": "", "a/z.yaml": "", "c.yaml": "", "a/y/x.yaml": "", "a/w.yaml": ""})

		// when
		visited := walked(t, root, nil)

		// then
		assert.Equal(t, []string{"b.yaml", "c.yaml", "a/w.yaml", "a/z.yaml", "a/y/x.yaml"}, visited)
	})

	t.Run("should visit a link to a file and never enter a link to a directory when it meets them", func(t *testing.T) {
		t.Parallel()
		// given
		root := t.TempDir()
		layout(t, root, map[string]string{"real/action.yaml": ""})
		require.NoError(t, os.Symlink(filepath.Join(root, "real", "action.yaml"), filepath.Join(root, "linked.yaml")))
		require.NoError(t, os.Symlink(filepath.Join(root, "real"), filepath.Join(root, "again")))

		// when
		visited := walked(t, root, nil)

		// then
		assert.Equal(t, []string{"linked.yaml", "real/action.yaml"}, visited)
	})

	t.Run("should not enter a skipped directory when skip names it", func(t *testing.T) {
		t.Parallel()
		// given
		root := t.TempDir()
		layout(t, root, map[string]string{".git/config.yaml": "", "kept/a.yaml": ""})

		// when
		visited := walked(t, root, func(name string) bool { return name == ".git" })

		// then
		assert.Equal(t, []string{"kept/a.yaml"}, visited)
	})

	t.Run("should stop with the visit's error when a visit fails", func(t *testing.T) {
		t.Parallel()
		// given
		root := t.TempDir()
		layout(t, root, map[string]string{"a/one.yaml": "", "b/two.yaml": ""})
		failure := errors.New("unreadable")

		// when
		err := filetext.Walk(root, nil, func(string) error { return failure })

		// then
		require.ErrorIs(t, err, failure)
	})

	t.Run("should fail when the root does not exist", func(t *testing.T) {
		t.Parallel()
		// given
		root := filepath.Join(t.TempDir(), "missing")

		// when
		err := filetext.Walk(root, nil, func(string) error { return nil })

		// then
		require.ErrorIs(t, err, os.ErrNotExist)
	})
}

func TestLines(t *testing.T) {
	t.Parallel()

	cases := map[string]struct {
		text     string
		expected []string
	}{
		"should hold no line when the text is empty":               {text: "", expected: nil},
		"should not start an empty line when the text ends a line": {text: "a\n", expected: []string{"a"}},
		"should keep an empty line when the text holds one":        {text: "a\n\n", expected: []string{"a", ""}},
		"should keep the last line when it has no terminator":      {text: "a\nb", expected: []string{"a", "b"}},
		"should split on every line break when the text mixes them": {
			text:     "a\r\nb\rc\n",
			expected: []string{"a", "b", "c"},
		},
		"should hold one empty line when the text is a single line end": {text: "\n", expected: []string{""}},
	}
	for name, scenario := range cases {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			// given
			text := scenario.text

			// when
			lines := filetext.Lines(text)

			// then
			assert.Equal(t, scenario.expected, lines)
		})
	}
}

func TestComments(t *testing.T) {
	t.Parallel()

	t.Run("should drop only whole-line comments when it strips a shell body", func(t *testing.T) {
		t.Parallel()
		// given
		text := "set -e\n  # a comment about $(SECRET)\necho \"#not a comment\"\n\t#tabbed\n"

		// when
		stripped := filetext.StripComments(text)

		// then
		assert.Equal(t, "set -e\necho \"#not a comment\"", stripped)
		assert.True(t, filetext.IsComment("   # x"))
		assert.False(t, filetext.IsComment("echo # x"))
	})

	t.Run("should read a file with every line break as a newline when the file uses CRLF", func(t *testing.T) {
		t.Parallel()
		// given
		path := filepath.Join(t.TempDir(), "run.sh")
		require.NoError(t, os.WriteFile(path, []byte("a\r\nb\rc"), 0o600))

		// when
		text, err := filetext.Read(path)

		// then
		require.NoError(t, err)
		assert.Equal(t, "a\nb\nc", text)
	})

	t.Run("should fail when the file cannot be read", func(t *testing.T) {
		t.Parallel()
		// given
		path := filepath.Join(t.TempDir(), "missing.sh")

		// when
		_, err := filetext.Read(path)

		// then
		require.ErrorIs(t, err, os.ErrNotExist)
	})
}
