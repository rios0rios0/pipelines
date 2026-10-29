package main

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestParseDocumentTypes(t *testing.T) {
	t.Parallel()

	t.Run("should read `on` as a string key when a workflow names its trigger", func(t *testing.T) {
		t.Parallel()
		// given
		text := "on:\n  push:\n"

		// when
		document := parsed(t, text)

		// then
		assert.True(t, document.has("on"))
		assert.True(t, document.get("on").has("push"))
	})

	t.Run("should keep the YAML 1.1 booleans as strings when they are plain scalars", func(t *testing.T) {
		t.Parallel()
		// given
		text := "a: yes\nb: no\nc: on\nd: off\ne: true\n"

		// when
		document := parsed(t, text)

		// then
		for _, key := range []string{"a", "b", "c", "d"} {
			assert.True(t, document.get(key).is(stringKind), key)
		}
		assert.Equal(t, "True", document.get("e").repr())
	})

	t.Run("should resolve the core types when scalars are written plainly", func(t *testing.T) {
		t.Parallel()
		// given
		text := "a: ~\nb: 0x1F\nc: 1_000\nd: 1.5\ne: .inf\nf: 2020-01-01\ng: '12'\nh: |\n  text\n"

		// when
		document := parsed(t, text)

		// then
		assert.Equal(t, "{'a': None, 'b': 31, 'c': 1000, 'd': 1.5, 'e': inf, 'f': '2020-01-01', 'g': '12', "+
			"'h': 'text\\n'}", document.repr())
	})

	t.Run("should read an empty stream as null", func(t *testing.T) {
		t.Parallel()
		// given
		text := "# only a comment\n"

		// when
		document := parsed(t, text)

		// then
		assert.True(t, document.is(nullKind))
	})
}

func TestParseDocumentRefusals(t *testing.T) {
	t.Parallel()

	cases := map[string]struct {
		text   string
		flavor dialect
		reason string
	}{
		"should refuse a key the mapping repeats": {
			"jobs: {}\njobs: {a: 1}\n", standardYAML, `line 2: mapping key "jobs" already defined at line 1`,
		},
		"should refuse an integer key the mapping repeats in another spelling": {
			"1: a\n01: b\n", standardYAML, `mapping key "1" already defined at line 1`,
		},
		"should refuse a stream of two documents": {
			"a: 1\n---\nb: 2\n", standardYAML, errSeveralDocuments.Error(),
		},
		"should refuse a tag YAML does not define when the file is not GitLab CI": {
			"image: !reference [ .go, image ]\n", standardYAML, "cannot read a sequence tagged !reference",
		},
		"should refuse !reference on a scalar when the file is GitLab CI": {
			"image: !reference .go\n", gitlabYAML, "cannot read a scalar tagged !reference",
		},
		"should refuse a mapping key that is a sequence": {
			"? [a, b]\n: c\n", standardYAML, "a mapping key must be a scalar, not a sequence",
		},
		"should refuse a merge key that names a scalar": {
			"a: &x 1\nb:\n  <<: *x\n", standardYAML, "a merge key takes a mapping or a list of mappings",
		},
		"should refuse a binary scalar, which nothing here reads": {
			"a: !!binary aGVsbG8=\n", standardYAML, "cannot read a scalar tagged !!binary",
		},
		"should refuse text that is not YAML": {
			"a: [1, 2\n", standardYAML, "did not find expected ',' or ']'",
		},
	}
	for name, values := range cases {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			// given
			text := []byte(values.text)

			// when
			_, err := parseDocument(text, values.flavor)

			// then
			require.ErrorContains(t, err, values.reason)
		})
	}
}

func TestParseDocumentReferences(t *testing.T) {
	t.Parallel()

	t.Run("should read GitLab's !reference as the sequence it is written as", func(t *testing.T) {
		t.Parallel()
		// given
		text := []byte("image: !reference [ .go, image ]\n")

		// when
		document, err := parseDocument(text, gitlabYAML)

		// then
		require.NoError(t, err)
		assert.Equal(t, "['.go', 'image']", document.get("image").repr())
	})

	t.Run("should share one value between an anchor and its aliases", func(t *testing.T) {
		t.Parallel()
		// given
		text := "a: &shared {x: 1}\nb: *shared\n"

		// when
		document := parsed(t, text)

		// then
		assert.Same(t, document.get("a"), document.get("b"))
	})

	t.Run("should let the mapping's own keys override what a merge key supplies", func(t *testing.T) {
		t.Parallel()
		// given
		text := "base: &base {a: 1, b: 2}\nchild:\n  c: 3\n  <<: *base\n  a: 9\n"

		// when
		document := parsed(t, text)

		// then
		assert.Equal(t, "{'a': 9, 'b': 2, 'c': 3}", document.get("child").repr())
	})

	t.Run("should let the first mapping of a merge list win when two supply one key", func(t *testing.T) {
		t.Parallel()
		// given
		text := "one: &one {k: first, x: 1}\ntwo: &two {k: second, y: 2}\nchild:\n  <<: [*one, *two]\n"

		// when
		document := parsed(t, text)

		// then
		assert.Equal(t, "{'k': 'first', 'y': 2, 'x': 1}", document.get("child").repr())
	})
}
