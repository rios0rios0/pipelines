package documents_test

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/rios0rios0/pipelines/internal/testsuites/dartpipeline/documents"
)

func TestYAMLToJSON(t *testing.T) {
	t.Parallel()

	t.Run("should keep `on` as a string key when converting a workflow", func(t *testing.T) {
		t.Parallel()
		// given
		input := []byte("on:\n  workflow_call:\n    inputs:\n      runs_on:\n        type: 'string'\n")

		// when
		output, err := documents.YAMLToJSON(input)

		// then
		require.NoError(t, err)
		assert.JSONEq(t, `{"on":{"workflow_call":{"inputs":{"runs_on":{"type":"string"}}}}}`, string(output))
	})

	t.Run("should keep booleans, numbers and null typed when converting scalars", func(t *testing.T) {
		t.Parallel()
		// given
		input := []byte("a: true\nb: 3\nc: 1.5\nd: ~\ne: '3'\nf: .nan\n")

		// when
		output, err := documents.YAMLToJSON(input)

		// then
		require.NoError(t, err)
		assert.JSONEq(t, `{"a":true,"b":3,"c":1.5,"d":null,"e":"3","f":".nan"}`, string(output))
	})

	t.Run("should keep a custom tag's plain value when converting a GitLab template", func(t *testing.T) {
		t.Parallel()
		// given
		input := []byte("job:\n  script:\n    - !reference [ .scripts-repo, before_script ]\n    - !custom 'text'\n")

		// when
		output, err := documents.YAMLToJSON(input)

		// then
		require.NoError(t, err)
		assert.JSONEq(t, `{"job":{"script":[[".scripts-repo","before_script"],"text"]}}`, string(output))
	})

	t.Run("should resolve anchors and let explicit keys win over merged ones", func(t *testing.T) {
		t.Parallel()
		// given
		input := []byte("base: &base\n  a: 1\n  b: 2\nother: &other\n  b: 3\n  c: 4\n" +
			"job:\n  <<: [*base, *other]\n  a: 9\n  copy: *base\n")

		// when
		output, err := documents.YAMLToJSON(input)

		// then
		require.NoError(t, err)
		assert.JSONEq(t, `{"base":{"a":1,"b":2},"other":{"b":3,"c":4},`+
			`"job":{"a":9,"b":2,"c":4,"copy":{"a":1,"b":2}}}`, string(output))
	})

	t.Run("should keep the last value when a key is repeated", func(t *testing.T) {
		t.Parallel()
		// given
		input := []byte("key: first\nkey: second\n")

		// when
		output, err := documents.YAMLToJSON(input)

		// then
		require.NoError(t, err)
		assert.JSONEq(t, `{"key":"second"}`, string(output))
	})

	t.Run("should convert an empty stream to null", func(t *testing.T) {
		t.Parallel()
		// given
		input := []byte("")

		// when
		output, err := documents.YAMLToJSON(input)

		// then
		require.NoError(t, err)
		assert.Equal(t, "null", string(output))
	})

	t.Run("should fail when the YAML is not valid", func(t *testing.T) {
		t.Parallel()
		// given
		input := []byte("key: [unclosed\n")

		// when
		_, err := documents.YAMLToJSON(input)

		// then
		require.Error(t, err)
	})

	t.Run("should fail when the stream holds several documents", func(t *testing.T) {
		t.Parallel()
		// given
		input := []byte("a: 1\n---\nb: 2\n")

		// when
		_, err := documents.YAMLToJSON(input)

		// then
		require.ErrorIs(t, err, documents.ErrSeveralDocuments)
	})
}

func TestCheckXML(t *testing.T) {
	t.Parallel()

	t.Run("should accept a Cobertura report with its declaration and doctype", func(t *testing.T) {
		t.Parallel()
		// given
		input := []byte("<?xml version=\"1.0\" ?>\n<!DOCTYPE coverage SYSTEM 'https://x/coverage-04.dtd'>\n" +
			"<coverage line-rate=\"1\"><class name='q\"q' filename=\"a&amp;b\"/></coverage>\n")

		// when
		err := documents.CheckXML(input)

		// then
		require.NoError(t, err)
	})

	t.Run("should fail when a tag is not closed by its own end tag", func(t *testing.T) {
		t.Parallel()
		// given
		input := []byte("<a><b></a>")

		// when
		err := documents.CheckXML(input)

		// then
		require.Error(t, err)
	})

	t.Run("should fail when an ampersand is not escaped", func(t *testing.T) {
		t.Parallel()
		// given
		input := []byte("<a>x & y</a>")

		// when
		err := documents.CheckXML(input)

		// then
		require.Error(t, err)
	})

	t.Run("should fail when the document holds a character XML forbids", func(t *testing.T) {
		t.Parallel()
		// given
		input := []byte("<a>\x01</a>")

		// when
		err := documents.CheckXML(input)

		// then
		require.Error(t, err)
	})

	t.Run("should fail when an element is left open", func(t *testing.T) {
		t.Parallel()
		// given
		input := []byte("<a><b/>")

		// when
		err := documents.CheckXML(input)

		// then
		require.Error(t, err)
	})

	t.Run("should fail when there are two root elements", func(t *testing.T) {
		t.Parallel()
		// given
		input := []byte("<a/><b/>")

		// when
		err := documents.CheckXML(input)

		// then
		require.ErrorIs(t, err, documents.ErrSeveralRoots)
	})

	t.Run("should fail when text sits outside the root element", func(t *testing.T) {
		t.Parallel()
		// given
		input := []byte("<a/>trailing")

		// when
		err := documents.CheckXML(input)

		// then
		require.ErrorIs(t, err, documents.ErrTextOutsideRoot)
	})

	t.Run("should fail when there is no element at all", func(t *testing.T) {
		t.Parallel()
		// given
		input := []byte("<?xml version=\"1.0\"?>\n")

		// when
		err := documents.CheckXML(input)

		// then
		require.ErrorIs(t, err, documents.ErrNoRoot)
	})
}

func TestRun(t *testing.T) {
	t.Parallel()

	t.Run("should print a YAML file as JSON and exit 0", func(t *testing.T) {
		t.Parallel()
		// given
		path := writeFile(t, "workflow.yaml", "jobs:\n  test:\n    runs-on: 'ubuntu-latest'\n")
		var stdout, stderr bytes.Buffer

		// when
		status := documents.Run([]string{"yaml", path}, &stdout, &stderr)

		// then
		assert.Equal(t, 0, status)
		assert.JSONEq(t, `{"jobs":{"test":{"runs-on":"ubuntu-latest"}}}`, stdout.String())
		assert.Empty(t, stderr.String())
	})

	t.Run("should exit 1 naming the file when it is not valid YAML", func(t *testing.T) {
		t.Parallel()
		// given
		path := writeFile(t, "broken.yaml", "key: [unclosed\n")
		var stdout, stderr bytes.Buffer

		// when
		status := documents.Run([]string{"yaml", path}, &stdout, &stderr)

		// then
		assert.Equal(t, 1, status)
		assert.Contains(t, stderr.String(), path)
	})

	t.Run("should exit 0 when every XML file is well-formed", func(t *testing.T) {
		t.Parallel()
		// given
		first := writeFile(t, "a.xml", "<a/>")
		second := writeFile(t, "b.xml", "<b>text</b>\n")
		var stdout, stderr bytes.Buffer

		// when
		status := documents.Run([]string{"xml", first, second}, &stdout, &stderr)

		// then
		assert.Equal(t, 0, status)
		assert.Empty(t, stderr.String())
	})

	t.Run("should exit 1 naming the first XML file that is not well-formed", func(t *testing.T) {
		t.Parallel()
		// given
		good := writeFile(t, "good.xml", "<a/>")
		bad := writeFile(t, "bad.xml", "<a><b></a>")
		var stdout, stderr bytes.Buffer

		// when
		status := documents.Run([]string{"xml", good, bad}, &stdout, &stderr)

		// then
		assert.Equal(t, 1, status)
		assert.Contains(t, stderr.String(), bad)
		assert.NotContains(t, stderr.String(), good)
	})

	t.Run("should exit 1 when a file cannot be read", func(t *testing.T) {
		t.Parallel()
		// given
		missing := filepath.Join(t.TempDir(), "missing.xml")
		var stdout, stderr bytes.Buffer

		// when
		status := documents.Run([]string{"xml", missing}, &stdout, &stderr)

		// then
		assert.Equal(t, 1, status)
		assert.Contains(t, stderr.String(), missing)
	})

	t.Run("should exit 2 when the command is not known", func(t *testing.T) {
		t.Parallel()
		// given
		args := []string{"json", "file"}
		var stdout, stderr bytes.Buffer

		// when
		status := documents.Run(args, &stdout, &stderr)

		// then
		assert.Equal(t, 2, status)
		assert.Contains(t, stderr.String(), "usage:")
	})

	t.Run("should exit 2 when a command is given the wrong number of files", func(t *testing.T) {
		t.Parallel()
		// given
		args := [][]string{{"yaml"}, {"yaml", "a", "b"}, {"xml"}, {}}

		for _, arguments := range args {
			var stdout, stderr bytes.Buffer

			// when
			status := documents.Run(arguments, &stdout, &stderr)

			// then
			assert.Equal(t, 2, status, "arguments %q", arguments)
		}
	})
}

func writeFile(t *testing.T, name, content string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), name)
	require.NoError(t, os.WriteFile(path, []byte(content), 0o600))
	return path
}
