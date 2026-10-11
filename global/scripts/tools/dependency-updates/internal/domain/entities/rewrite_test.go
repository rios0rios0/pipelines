package entities_test

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/rios0rios0/pipelines/global/scripts/tools/dependency-updates/internal/domain/entities"
)

func TestRepinAction(t *testing.T) {
	t.Parallel()

	t.Run("should re-pin the action and its sub-path actions and nothing else", func(t *testing.T) {
		t.Parallel()
		// given
		old, next := sha("1")[:40], sha("8")[:40]
		text := "      - uses: 'someorg/someaction@" + old + "' # v3.1.0\n" +
			"      - uses: 'someorg/someaction/sub@" + old + "' # v3.1.0\n" +
			"      - uses: 'someorg/someactionx@" + old + "' # v3.1.0\n"

		// when
		rewritten, changes := entities.RepinAction(text, "someorg/someaction", next, "v4.0.0")

		// then
		assert.Equal(t, 2, changes)
		assert.Contains(t, rewritten, "someorg/someaction@"+next+"' # v4.0.0")
		assert.Contains(t, rewritten, "someorg/someaction/sub@"+next+"' # v4.0.0")
		assert.Contains(t, rewritten, "someorg/someactionx@"+old+"' # v3.1.0")
	})

	t.Run("should change nothing already on the target", func(t *testing.T) {
		t.Parallel()
		// given
		pinned := sha("8")[:40]
		text := "- uses: 'someorg/someaction@" + pinned + "' # v4.0.0\n"

		// when
		rewritten, changes := entities.RepinAction(text, "someorg/someaction", pinned, "v4.0.0")

		// then
		assert.Zero(t, changes)
		assert.Equal(t, text, rewritten)
	})
}

func TestRepinImage(t *testing.T) {
	t.Parallel()

	t.Run("should never rewrite a longer reference that ends the same way", func(t *testing.T) {
		t.Parallel()
		// given
		old := "python:3.13-slim@sha256:" + sha("a")
		text := "image: '" + old + "'\nimage: 'mirror.example/python:3.13-slim@sha256:" + sha("a") + "'\n"

		// when
		rewritten, count := entities.RepinImage(text, old, "python:3.13-slim@sha256:"+sha("c"))

		// then
		assert.Equal(t, 1, count)
		assert.Contains(t, rewritten, "image: 'python:3.13-slim@sha256:"+sha("c")+"'")
		assert.Contains(t, rewritten, "mirror.example/python:3.13-slim@sha256:"+sha("a"))
	})
}

func TestRewriteManifest(t *testing.T) {
	t.Parallel()

	t.Run("should rewrite the pin and its digests and keep the line endings", func(t *testing.T) {
		t.Parallel()
		// given
		text := "TOOL_PINNED_VERSION=\"1.2.3\"\r\nTOOL_SHA256_AMD64=\"" + sha("1") + "\"\r\n"
		entry := entities.ParseManifest(text)[0]
		digests := []entities.DigestPlan{{Var: "TOOL_SHA256_AMD64", Old: sha("1"), New: sha("4")}}

		// when
		rewritten, err := entities.RewriteManifest(text, entry, "1.3.0", digests)

		// then
		require.NoError(t, err)
		assert.Equal(t, "TOOL_PINNED_VERSION=\"1.3.0\"\r\nTOOL_SHA256_AMD64=\""+sha("4")+"\"\r\n", rewritten)
	})

	t.Run("should keep a package spec's shape", func(t *testing.T) {
		t.Parallel()
		// given
		text := "PDM_SPEC=\"${PDM_SPEC:-pdm==2.29.0}\"\n"
		entry := entities.ParseManifest("# upstream: pypi pdm\n" + text)[0]

		// when
		rewritten, err := entities.RewriteManifest(text, entry, "2.29.2", nil)

		// then
		require.NoError(t, err)
		assert.Equal(t, "PDM_SPEC=\"${PDM_SPEC:-pdm==2.29.2}\"\n", rewritten)
	})

	t.Run("should refuse when the line is not there exactly once", func(t *testing.T) {
		t.Parallel()
		// given
		text := "TOOL_PINNED_VERSION=\"1.2.3\"\nTOOL_PINNED_VERSION=\"1.2.3\"\n"
		entry := entities.ParseManifest(text)[0]

		// when
		_, err := entities.RewriteManifest(text, entry, "1.3.0", nil)

		// then
		var refused *entities.RefusedError
		require.ErrorAs(t, err, &refused)
		assert.Contains(t, refused.Reason, "expected exactly one")
	})
}

func TestAlignCopies(t *testing.T) {
	t.Parallel()

	t.Run("should move a copy left behind by a bump and flag one that had already drifted", func(t *testing.T) {
		t.Parallel()
		// given
		inline := entities.InlineCopies()[0]
		text := `pip install --only-binary :all: "pdm==2.29.0"` + "\n" + `pip install "pdm==2.20.0"` + "\n"

		// when
		rewritten, changes := entities.AlignCopies(text, inline, "2.29.2", "2.29.0", "ci.yaml")

		// then
		assert.Contains(t, rewritten, `"pdm==2.29.2"`)
		assert.NotContains(t, rewritten, "2.20.0")
		require.Len(t, changes, 2)
		assert.False(t, changes[0].Drifted)
		assert.True(t, changes[1].Drifted)
	})
}

func TestFingerprint(t *testing.T) {
	t.Parallel()

	t.Run("should not depend on the order updates are listed in", func(t *testing.T) {
		t.Parallel()
		// given
		first := &entities.Task{
			Group: entities.GroupAction,
			Label: "a/b",
			Apply: &entities.Plan{New: "v2", SHA: sha("2")[:40]},
		}
		second := &entities.Task{Group: entities.GroupManifest, Label: "TOOL", Apply: &entities.Plan{New: "1.3.0"}}

		// when
		forward := entities.Fingerprint([]*entities.Task{first, second}, nil)
		backward := entities.Fingerprint([]*entities.Task{second, first}, nil)

		// then
		assert.Equal(t, forward, backward)
	})

	t.Run("should change when a re-merged vendored file changes", func(t *testing.T) {
		t.Parallel()
		// given
		task := func(merged string) *entities.Task {
			return &entities.Task{Group: entities.GroupManifest, Label: "CONFIG", Apply: &entities.Plan{
				New: "2.14.0", Vendored: &entities.VendoredPlan{Merged: merged},
			}}
		}

		// when
		before := entities.Fingerprint([]*entities.Task{task("a")}, nil)
		after := entities.Fingerprint([]*entities.Task{task("b")}, nil)

		// then
		assert.NotEqual(t, before, after)
	})
}

func TestPublishedChecksum(t *testing.T) {
	t.Parallel()

	cases := map[string]struct {
		text, asset, want string
	}{
		"should read the GNU format": {
			text: sha(
				"a",
			) + "  tool_linux_amd64.tar.gz\n" + sha(
				"b",
			) + "  other\n",
			asset: "tool_linux_amd64.tar.gz",
			want:  sha("a"),
		},
		"should read binary mode": {
			text: sha("b") + " *hadolint-linux-x86_64\n", asset: "hadolint-linux-x86_64", want: sha("b"),
		},
		"should read the BSD format by its exact algorithm": {
			text:  "SHA3-256 (yq_linux_amd64) = " + sha("a") + "\nSHA256 (yq_linux_amd64) = " + sha("c") + "\n",
			asset: "yq_linux_amd64", want: sha("c"),
		},
		"should read a bare per-asset digest": {
			text:  sha("c") + "\n",
			asset: "codeql-bundle-linux64.tar.gz",
			want:  sha("c"),
		},
		"should not invent an asset it does not list": {
			text: sha("a") + "  something_else\n", asset: "tool_linux_amd64.tar.gz", want: "",
		},
	}
	for name, values := range cases {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			// given / when
			published := entities.PublishedChecksum(values.text, values.asset)

			// then
			assert.Equal(t, values.want, published)
		})
	}
}
