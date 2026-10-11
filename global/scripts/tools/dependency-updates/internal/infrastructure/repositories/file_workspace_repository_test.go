package repositories_test

import (
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	infrastructure "github.com/rios0rios0/pipelines/global/scripts/tools/dependency-updates/internal/infrastructure/repositories"
)

func layout(t *testing.T, files map[string]string) string {
	t.Helper()
	root := t.TempDir()
	for name, content := range files {
		path := filepath.Join(root, filepath.FromSlash(name))
		require.NoError(t, os.MkdirAll(filepath.Dir(path), 0o750))
		require.NoError(t, os.WriteFile(path, []byte(content), 0o600))
	}
	return root
}

func openWorkspace(t *testing.T, root string) *infrastructure.FileWorkspaceRepository {
	t.Helper()
	workspace, err := infrastructure.NewFileWorkspaceRepository(root)
	require.NoError(t, err)
	t.Cleanup(func() { _ = workspace.Close() })
	return workspace
}

func TestFileWorkspaceRepositoryListing(t *testing.T) {
	t.Parallel()

	t.Run(
		"should list a directory's files before its subdirectories and skip what is never scanned",
		func(t *testing.T) {
			t.Parallel()
			// given
			root := layout(t, map[string]string{
				"b.yaml": "", "a/z.yml": "", "a/Dockerfile.alpine": "", ".git/config.yaml": "",
				"node_modules/x.yaml": "", ".pipelines/library.yaml": "", "build/report.yaml": "",
			})

			// when
			workspace := openWorkspace(t, root)

			// then
			assert.Equal(t, []string{"b.yaml", "a/z.yml"}, workspace.YAMLFiles())
			assert.Equal(t, []string{"a/Dockerfile.alpine"}, workspace.Dockerfiles())
		},
	)
}

func TestFileWorkspaceRepositoryWriting(t *testing.T) {
	t.Parallel()

	t.Run("should change only the bytes an edit names, keeping CRLF", func(t *testing.T) {
		t.Parallel()
		// given
		root := layout(t, map[string]string{"pins.yaml": "a: 1\r\nb: 2\r\n"})
		workspace := openWorkspace(t, root)

		// when
		set := workspace.Set("pins.yaml", "a: 1\r\nb: 3\r\n")
		written, err := workspace.Write()

		// then
		require.NoError(t, err)
		assert.True(t, set)
		assert.Equal(t, []string{"pins.yaml"}, written)
		content, _ := os.ReadFile(filepath.Join(root, "pins.yaml"))
		assert.Equal(t, "a: 1\r\nb: 3\r\n", string(content))
	})

	t.Run("should create a new file and its directories", func(t *testing.T) {
		t.Parallel()
		// given
		root := layout(t, map[string]string{})
		workspace := openWorkspace(t, root)

		// when
		workspace.Set(".changes/unreleased/1-abcd.yaml", "kind: 'Changed'\n")
		_, err := workspace.Write()

		// then
		require.NoError(t, err)
		assert.FileExists(t, filepath.Join(root, ".changes", "unreleased", "1-abcd.yaml"))
	})

	t.Run("should never write through a symlink", func(t *testing.T) {
		t.Parallel()
		// given
		root := layout(t, map[string]string{"real.yaml": "x: 1\n"})
		require.NoError(t, os.Symlink("real.yaml", filepath.Join(root, "link.yaml")))
		workspace := openWorkspace(t, root)

		// when
		text := workspace.Text("link.yaml")
		set := workspace.Set("link.yaml", "x: 2\n")

		// then
		assert.Equal(t, "x: 1\n", text, "a symlink is still read")
		assert.False(t, set)
	})

	t.Run("should never write a file that is not valid UTF-8", func(t *testing.T) {
		t.Parallel()
		// given
		root := layout(t, map[string]string{"binary.yaml": string([]byte{0xff, 0xfe, 'x'})})
		workspace := openWorkspace(t, root)

		// when
		set := workspace.Set("binary.yaml", "x")

		// then
		assert.False(t, set)
	})

	t.Run("should not read through a symlink that leaves the repository", func(t *testing.T) {
		t.Parallel()
		// given
		outside := layout(t, map[string]string{"secret.yaml": "token: fixture-token-placeholder\n"})
		root := layout(t, map[string]string{})
		require.NoError(t, os.Symlink(filepath.Join(outside, "secret.yaml"), filepath.Join(root, "escape.yaml")))
		workspace := openWorkspace(t, root)

		// when
		text := workspace.Text("escape.yaml")

		// then
		assert.Empty(t, text)
	})
}

func TestGitMergeRepository(t *testing.T) {
	t.Parallel()
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("git is not installed")
	}

	t.Run("should carry local adjustments onto an upstream change", func(t *testing.T) {
		t.Parallel()
		// given
		base := "one\ntwo\nthree\nfour\nfive\n"
		ours := base + "local adjustment\n"
		theirs := "ONE\ntwo\nthree\nfour\nfive\n"

		// when
		merged, conflicts, err := infrastructure.NewGitMergeRepository().Merge(ours, base, theirs)

		// then
		require.NoError(t, err)
		assert.Zero(t, conflicts)
		assert.Equal(t, "ONE\ntwo\nthree\nfour\nfive\nlocal adjustment\n", merged)
	})

	t.Run("should count the regions both sides changed", func(t *testing.T) {
		t.Parallel()
		// given
		base := "value: 1\n"

		// when
		_, conflicts, err := infrastructure.NewGitMergeRepository().Merge("value: 2\n", base, "value: 3\n")

		// then
		require.NoError(t, err)
		assert.Equal(t, 1, conflicts)
	})
}

func TestJSONSettingsRepository(t *testing.T) {
	t.Parallel()

	t.Run("should read every decision the file records", func(t *testing.T) {
		t.Parallel()
		// given
		root := layout(t, map[string]string{".dependency-updates.json": `{
			"ignore": ["alpine:edge"],
			"cooldown": {"days": 3, "exempt": ["rios0rios0/*"]},
			"vulnerabilities": {"accept": [{"id": "GHSA-x", "reason": "not reachable", "until": "2026-12-31"}]}
		}`})
		var warnings bytes.Buffer

		// when
		settings, err := infrastructure.NewJSONSettingsRepository(openWorkspace(t, root), &warnings).Load()

		// then
		require.NoError(t, err)
		assert.Equal(t, []string{"alpine:edge"}, settings.Ignore)
		assert.True(t, settings.HasCooldown)
		assert.Equal(t, []string{"rios0rios0/*"}, settings.CooldownExempt)
		require.Len(t, settings.Acceptances, 1)
		assert.Empty(t, warnings.String())
	})

	t.Run("should refuse an acceptance with no reason or no expiry", func(t *testing.T) {
		t.Parallel()
		// given
		root := layout(t, map[string]string{".dependency-updates.json": `{"vulnerabilities": {"accept": [
			{"id": "GHSA-x", "until": "2026-12-31"}, {"id": "GHSA-y", "reason": "forever"}
		]}}`})
		var warnings bytes.Buffer

		// when
		settings, err := infrastructure.NewJSONSettingsRepository(openWorkspace(t, root), &warnings).Load()

		// then
		require.NoError(t, err)
		assert.Empty(t, settings.Acceptances)
		assert.Contains(t, warnings.String(), "needs an id, a reason and an `until` date")
	})

	t.Run("should apply nothing from a file it cannot read", func(t *testing.T) {
		t.Parallel()
		// given
		root := layout(t, map[string]string{".dependency-updates.json": `{not json`})
		var warnings bytes.Buffer

		// when
		settings, err := infrastructure.NewJSONSettingsRepository(openWorkspace(t, root), &warnings).Load()

		// then
		require.NoError(t, err)
		assert.Empty(t, settings.Ignore)
		assert.False(t, settings.HasCooldown)
		assert.Contains(t, warnings.String(), "applying nothing from it")
	})
}
