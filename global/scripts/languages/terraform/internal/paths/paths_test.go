package paths_test

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/rios0rios0/pipelines/global/scripts/languages/terraform/internal/paths"
)

// tree builds `files` under a fresh directory, resolved, and returns it.
func tree(t *testing.T, files ...string) string {
	t.Helper()
	root, err := filepath.EvalSymlinks(t.TempDir())
	require.NoError(t, err)
	for _, file := range files {
		path := filepath.Join(root, file)
		require.NoError(t, os.MkdirAll(filepath.Dir(path), 0o750))
		require.NoError(t, os.WriteFile(path, nil, 0o600))
	}
	return root
}

func TestResolve(t *testing.T) {
	t.Parallel()

	t.Run("should follow relative and absolute symlinks when resolving", func(t *testing.T) {
		t.Parallel()
		// given
		root := tree(t, "a/b/c/file", "d/file")
		require.NoError(t, os.Symlink("a/b", filepath.Join(root, "relative")))
		require.NoError(t, os.Symlink(filepath.Join(root, "d"), filepath.Join(root, "absolute")))

		// when
		relative, errRelative := paths.Resolve(root + "/relative/c")
		absolute, errAbsolute := paths.Resolve(root + "/absolute/file")

		// then
		require.NoError(t, errRelative)
		require.NoError(t, errAbsolute)
		assert.Equal(t, root+"/a/b/c", relative)
		assert.Equal(t, root+"/d/file", absolute)
	})

	t.Run("should keep a missing component and a symlink loop as written when resolving", func(t *testing.T) {
		t.Parallel()
		// given
		root := tree(t)
		require.NoError(t, os.Symlink("loop-b", filepath.Join(root, "loop-a")))
		require.NoError(t, os.Symlink("loop-a", filepath.Join(root, "loop-b")))

		// when
		missing, errMissing := paths.Resolve(root + "/nowhere/../x//y/./")
		loop, errLoop := paths.Resolve(root + "/loop-a/child")

		// then
		require.NoError(t, errMissing)
		require.NoError(t, errLoop)
		assert.Equal(t, root+"/x/y", missing)
		assert.Equal(t, root+"/loop-a/child", loop)
	})
}

func TestClean(t *testing.T) {
	t.Parallel()

	t.Run("should drop doubled slashes, dots and a trailing slash but keep parents when cleaning", func(t *testing.T) {
		t.Parallel()
		// given
		messy := "/repo//build/./reports/../x/"

		// when
		cleaned := paths.Clean(messy)

		// then
		assert.Equal(t, "/repo/build/reports/../x", cleaned)
	})

	t.Run("should keep exactly two leading slashes and read nothing as the current directory", func(t *testing.T) {
		t.Parallel()
		// given
		names := []string{"//share/x", "///x", ""}

		// when
		cleaned := []string{paths.Clean(names[0]), paths.Clean(names[1]), paths.Clean(names[2])}

		// then
		assert.Equal(t, []string{"//share/x", "/x", "."}, cleaned)
	})
}

func TestSort(t *testing.T) {
	t.Parallel()

	t.Run("should order paths component by component when sorting", func(t *testing.T) {
		t.Parallel()
		// given
		names := []string{"/a-c", "/a/b/c", "/a.b/c", "/a/b", "/a", "/a/.b"}

		// when
		paths.Sort(names)

		// then
		assert.Equal(t, []string{"/a", "/a/.b", "/a/b", "/a/b/c", "/a-c", "/a.b/c"}, names)
	})
}

func TestRelativeTo(t *testing.T) {
	t.Parallel()

	t.Run("should give the path below the base when it is inside", func(t *testing.T) {
		t.Parallel()
		// given
		base := "/repo"

		// when
		inside, insideOK := paths.RelativeTo("/repo/stacks/app", base)
		same, sameOK := paths.RelativeTo("/repo", base)

		// then
		assert.True(t, insideOK)
		assert.True(t, sameOK)
		assert.Equal(t, "stacks/app", inside)
		assert.Equal(t, ".", same)
	})

	t.Run("should refuse a sibling that only shares a prefix", func(t *testing.T) {
		t.Parallel()
		// given
		base := "/repo"

		// when
		_, ok := paths.RelativeTo("/repository/x", base)

		// then
		assert.False(t, ok)
	})
}

func TestRGlob(t *testing.T) {
	t.Parallel()

	t.Run("should find hidden and nested matches and never descend a symlink when globbing", func(t *testing.T) {
		t.Parallel()
		// given
		root := tree(t, "a/root.hcl", ".hidden/root.hcl", "real/sub/root.hcl", ".terraform/root.hcl")
		require.NoError(t, os.Symlink("real", filepath.Join(root, "link")))

		// when
		found := paths.RGlob(root, "root.hcl", ".terraform")

		// then
		assert.Equal(t, []string{root + "/.hidden/root.hcl", root + "/a/root.hcl", root + "/real/sub/root.hcl"}, found)
	})

	t.Run("should match a dangling symlink by its name when globbing", func(t *testing.T) {
		t.Parallel()
		// given
		root := tree(t, "main.tf")
		require.NoError(t, os.Symlink("nowhere", filepath.Join(root, "main_b.tf")))

		// when
		found := paths.Glob(root, "main*.tf")

		// then
		assert.Equal(t, []string{root + "/main.tf", root + "/main_b.tf"}, found)
	})
}

func TestMatch(t *testing.T) {
	t.Parallel()

	t.Run("should let a star cross directories and a set match one character when matching", func(t *testing.T) {
		t.Parallel()
		// given
		pattern := "modules/*/providers.[a-u]f"

		// when
		matched := paths.Match("modules/a/b/providers.tf", pattern)

		// then
		assert.True(t, matched)
	})

	t.Run("should treat an unclosed bracket literally and a reversed range as matching nothing", func(t *testing.T) {
		t.Parallel()
		// given
		names := map[string]string{"[x": "[x", "z-a": "[z-a]"}

		// when
		literal := paths.Match(names["[x"], "[x")
		reversed := paths.Match("z", names["z-a"])

		// then
		assert.True(t, literal)
		assert.False(t, reversed)
	})
}
