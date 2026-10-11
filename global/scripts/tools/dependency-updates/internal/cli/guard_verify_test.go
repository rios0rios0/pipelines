package cli_test

import (
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
)

func guardAnswers(scenario string) map[string]any {
	pulls := "GET " + api + "/owner/repo/pulls?state=closed&head=owner%3Achore%2Fdependency-updates&per_page=100"
	compare := "GET " + api + "/owner/repo/compare/main...chore/dependency-updates"
	marker := "<!-- dependency-updates-fingerprint: " + repeat("d", 64) + " -->"
	bot := map[string]any{"sha": repeat("a", 40), "parents": []any{map[string]any{}},
		"commit": map[string]any{"message": "chore(deps): bumped\n\nDependency-Updates-Fingerprint: x"}}
	merge := map[string]any{"sha": repeat("b", 40), "parents": []any{map[string]any{}, map[string]any{}},
		"commit": map[string]any{"message": "Merge branch 'main'"}}
	person := map[string]any{"sha": repeat("c", 40), "parents": []any{map[string]any{}},
		"commit": map[string]any{"message": "fix: reverted the yq bump"}}
	scenarios := map[string]map[string]any{
		"declined": {pulls: []any{map[string]any{"number": 12, "merged_at": nil, "body": marker}},
			compare: map[string]any{"commits": []any{bot}}},
		"merged": {
			pulls:   []any{map[string]any{"number": 13, "merged_at": "2026-10-01T00:00:00Z", "body": marker}},
			compare: nil,
		},
		"edited":      {pulls: []any{}, compare: map[string]any{"commits": []any{bot, person}}},
		"updated":     {pulls: []any{}, compare: map[string]any{"commits": []any{bot, merge}}},
		"unreachable": {pulls: []any{}},
	}
	return scenarios[scenario]
}

func runGuard(t *testing.T, scenario, fingerprint string) outcome {
	t.Helper()
	workdir := t.TempDir()
	writeJSON(t, filepath.Join(workdir, "guard.json"), guardAnswers(scenario))
	return run(t, workdir, "guard", "--repository", "owner/repo", "--branch", "chore/dependency-updates",
		"--base", "main", "--fingerprint", fingerprint, "--fixture", "guard.json")
}

func TestGuardCommandLine(t *testing.T) {
	t.Parallel()

	cases := map[string]struct {
		scenario, want, reason string
		exit                   int
	}{
		"should not propose again a declined set": {
			scenario: "declined",
			want:     "proceed=false",
			reason:   "declined in #12",
		},
		"should not count a merged pull request as a no": {scenario: "merged", want: "proceed=true"},
		"should never overwrite a commit a person pushed": {
			scenario: "edited",
			want:     "proceed=false",
			reason:   "cccccccccccc",
		},
		"should treat an Update-branch merge as its own": {scenario: "updated", want: "proceed=true"},
		"should decide nothing when a lookup fails":      {scenario: "unreachable", exit: 2},
	}
	for name, values := range cases {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			// given / when
			result := runGuard(t, values.scenario, repeat("d", 64))

			// then
			assert.Equal(t, values.exit, result.exit, result.output())
			if values.want != "" {
				assert.Contains(t, result.stdout, values.want)
				assert.Contains(t, result.stdout, values.reason)
			} else {
				assert.NotContains(t, result.stdout, "proceed=true")
			}
		})
	}

	t.Run("should refuse a malformed fingerprint", func(t *testing.T) {
		t.Parallel()
		// given / when
		result := runGuard(t, "merged", "not-a-fingerprint")

		// then
		assert.Equal(t, 2, result.exit)
	})
}

func TestVerifyCommandLine(t *testing.T) {
	t.Parallel()

	pin := func(version, digest string) string {
		return "# upstream: github-release example/tool\n# osv: none\n" +
			"TOOL_PINNED_VERSION=\"" + version + "\"\n" +
			"# asset: https://github.com/example/tool/releases/download/v{version}/tool_{version}_linux_amd64.tar.gz\n" +
			"TOOL_SHA256_AMD64=\"" + digest + "\"\n"
	}
	verifyWorkdir := func(t *testing.T, headDigest string, published string) string {
		t.Helper()
		workdir := t.TempDir()
		writeFiles(t, filepath.Join(workdir, "base"), map[string]string{
			"global/scripts/shared/pinned-versions.sh": pin("1.2.3", repeat("1", 64)),
		})
		writeFiles(t, filepath.Join(workdir, "head"), map[string]string{
			"global/scripts/shared/pinned-versions.sh": pin("1.3.0", headDigest),
		})
		writeJSON(t, filepath.Join(workdir, "fixture.json"), map[string]any{
			"osv:*": []any{},
			"github-release:example/tool": map[string]any{"latest": "v1.3.0", "releases": []any{
				map[string]any{"version": "v1.3.0", "published": published}}},
			"GET " + api + "/example/tool/releases/tags/v1.3.0": map[string]any{"assets": []any{
				map[string]any{"name": "tool_1.3.0_linux_amd64.tar.gz", "digest": "sha256:" + repeat("4", 64)}}},
		})
		return workdir
	}
	verifyArguments := []string{"verify", "--base-dir", "base", "--repo-dir", "head", "--report", "out",
		"--fixture", "fixture.json", "--now", "2026-10-10T06:00:00Z"}

	t.Run("should verify a bump whose digest matches the release and whose release has aged", func(t *testing.T) {
		t.Parallel()
		// given
		workdir := verifyWorkdir(t, repeat("4", 64), "2026-09-01T00:00:00Z")

		// when
		result := run(t, workdir, verifyArguments...)

		// then
		assert.Equal(t, 0, result.exit, result.output())
		assert.Contains(t, read(t, filepath.Join(workdir, "out", "verification.md")), "**Verified:**")
	})

	t.Run("should fail a bump whose digest is not what upstream published", func(t *testing.T) {
		t.Parallel()
		// given
		workdir := verifyWorkdir(t, repeat("9", 64), "2026-09-01T00:00:00Z")

		// when
		result := run(t, workdir, verifyArguments...)

		// then
		assert.Equal(t, 1, result.exit)
		assert.Contains(t, read(t, filepath.Join(workdir, "out", "verification.md")), "**Not verified:**")
	})

	t.Run("should fail a bump to a release younger than the cooldown", func(t *testing.T) {
		t.Parallel()
		// given
		workdir := verifyWorkdir(t, repeat("4", 64), "2026-10-09T00:00:00Z")

		// when
		result := run(t, workdir, verifyArguments...)

		// then
		assert.Equal(t, 1, result.exit)
		assert.Contains(t, result.stdout, "cooldown")
	})

	t.Run("should require the base checkout", func(t *testing.T) {
		t.Parallel()
		// given / when
		result := run(t, t.TempDir(), "verify", "--repo-dir", "head")

		// then
		assert.Equal(t, 2, result.exit)
		assert.Contains(t, result.stderr, "--base-dir is required")
	})
}
