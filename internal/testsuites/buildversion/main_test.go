package main

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

const action = `on:
  workflow_call:
    inputs:
      version_build_arg: {type: string, required: false, default: ''}
inputs:
  version_build_arg:
    required: false
    default: ~
runs:
  using: composite
  steps:
    - uses: 'docker/login-action@x'
    - id: 'version'
      if: "inputs.version_build_arg != ''"
      run: |
        echo "${{ inputs.x }}"
      env: {DOCKERFILE: 'Dockerfile'}
    - id: 'build'
      uses: 'docker/build-push-action@x'
      with: {tags: [a, b]}
`

// file writes the action fixture, or `content`, and returns its path.
func file(t *testing.T, content string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "action.yaml")
	require.NoError(t, os.WriteFile(path, []byte(content), 0o600))
	return path
}

func TestAnswer(t *testing.T) {
	t.Parallel()

	cases := map[string]struct {
		expression string
		expected   string
	}{
		"should answer the value when a lookup chain names existing keys": {
			expression: "doc['inputs']['version_build_arg']['required']", expected: "False",
		},
		"should answer nothing when the value is null": {
			expression: "doc['inputs']['version_build_arg']['default']", expected: "",
		},
		"should read trigger as the on block when a workflow declares one": {
			expression: "trigger['workflow_call']['inputs']['version_build_arg']['type']", expected: "string",
		},
		"should find a step by its id when the fragment is one": {
			expression: "step(doc['runs']['steps'], 'version')['if']", expected: "inputs.version_build_arg != ''",
		},
		"should find a step by its uses when the fragment is part of one": {
			expression: "step(doc['runs']['steps'], 'build-push-action@')['id']", expected: "build",
		},
		"should answer whether a script holds an interpolation when asked with in": {
			expression: "'${{' in step(doc['runs']['steps'], 'version')['run']", expected: "True",
		},
		"should answer membership of a mapping's keys when the haystack is a mapping": {
			expression: "'DOCKERFILE' in step(doc['runs']['steps'], 'version')['env']", expected: "True",
		},
		"should answer membership of a list's items when the haystack is a list": {
			expression: "'c' in step(doc['runs']['steps'], 'build')['with']['tags']", expected: "False",
		},
		"should compare step positions when id_index and uses_index name steps": {
			expression: "id_index(doc['runs']['steps'], 'version') < uses_index(doc['runs']['steps'], 'login-action@')",
			expected:   "False",
		},
		"should compare two ids when both name steps": {
			expression: "id_index(doc['runs']['steps'], 'build') > id_index(doc['runs']['steps'], 'version')",
			expected:   "True",
		},
		"should index a list from the end when the index is negative": {
			expression: "doc['runs']['steps'][-1]['id']", expected: "build",
		},
		"should render a mapping the way the messages spell one": {
			expression: "step(doc['runs']['steps'], 'build')['with']", expected: "{'tags': ['a', 'b']}",
		},
		"should answer a KeyError when a key is missing": {
			expression: "doc['inputs']['missing']", expected: "<KeyError: 'missing'>",
		},
		"should answer a LookupError when no step matches": {
			expression: "step(doc['runs']['steps'], 'nothing')", expected: "<LookupError: no step matches 'nothing'>",
		},
		"should answer a ValueError when no step has the id": {
			expression: "id_index(doc['runs']['steps'], 'nothing')", expected: "<ValueError: 'nothing' is not in list>",
		},
		"should answer an IndexError when no step uses the fragment": {
			expression: "uses_index(doc['runs']['steps'], 'nothing@')",
			expected:   "<IndexError: list index out of range>",
		},
		"should answer a TypeError when a null is subscripted": {
			expression: "doc['inputs']['version_build_arg']['default']['x']",
			expected:   "<TypeError: 'NoneType' object is not subscriptable>",
		},
		"should answer a TypeError when a list is looked up by a key": {
			expression: "doc['runs']['steps']['x']",
			expected:   "<TypeError: list indices must be integers or slices, not str>",
		},
		"should answer a SyntaxError when the expression is malformed": {
			expression: "doc['runs'", expected: "<SyntaxError: expected \"]\">",
		},
		"should answer a NameError when the expression names something unknown": {
			expression: "document", expected: "<NameError: name 'document' is not defined>",
		},
	}
	path := file(t, action)
	for name, scenario := range cases {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			// given
			expression := scenario.expression

			// when
			result := answer(path, expression)

			// then
			assert.Equal(t, scenario.expected, result)
		})
	}

	t.Run("should answer a YAMLError when the file does not parse", func(t *testing.T) {
		t.Parallel()
		// given
		broken := file(t, "runs: [\n")

		// when
		result := answer(broken, "doc['runs']")

		// then
		assert.Contains(t, result, "<YAMLError: ")
	})
}

func TestTokenize(t *testing.T) {
	t.Parallel()

	t.Run("should read an escaped quote and backslash when a quoted text holds them", func(t *testing.T) {
		t.Parallel()
		// given
		source := `'it\'s \\ "x"'`

		// when
		tokens, err := tokenize(source)

		// then
		require.NoError(t, err)
		assert.Equal(t, []token{{kind: tokenText, text: `it's \ "x"`}, {kind: tokenEnd}}, tokens)
	})

	t.Run("should fail when a quoted text is not terminated", func(t *testing.T) {
		t.Parallel()
		// given
		source := "'open"

		// when
		_, err := tokenize(source)

		// then
		require.EqualError(t, err, "<SyntaxError: unterminated string literal>")
	})
}

func TestRun(t *testing.T) {
	t.Parallel()

	t.Run("should print the answer and exit 0 when the query is well formed", func(t *testing.T) {
		t.Parallel()
		// given
		path := file(t, action)
		var stdout, stderr bytes.Buffer

		// when
		status := run([]string{"query", path, "doc['runs']['using']"}, &stdout, &stderr)

		// then
		assert.Equal(t, 0, status)
		assert.Equal(t, "composite\n", stdout.String())
	})

	t.Run("should print the usage and exit 2 when the arguments are not a query", func(t *testing.T) {
		t.Parallel()
		// given
		var stdout, stderr bytes.Buffer

		// when
		status := run([]string{"query", "only-a-file"}, &stdout, &stderr)

		// then
		assert.Equal(t, exitUsage, status)
		assert.Contains(t, stderr.String(), "usage:")
	})
}
