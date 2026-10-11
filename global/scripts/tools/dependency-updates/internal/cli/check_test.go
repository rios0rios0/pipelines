package cli_test

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// checkWorkdir is a working directory holding the sample repository and a
// fixture of `answers`.
func checkWorkdir(t *testing.T, answers map[string]any) string {
	t.Helper()
	workdir := t.TempDir()
	sampleRepository(t, filepath.Join(workdir, "repo"))
	writeJSON(t, filepath.Join(workdir, "fixture.json"), answers)
	return workdir
}

func checkArguments(extra ...string) []string {
	return append([]string{"--repo-dir", "repo", "--report", "out", "--fixture", "fixture.json", "--now",
		"2026-10-10T06:00:00Z"}, extra...)
}

func TestCheckCommandLine(t *testing.T) {
	t.Parallel()

	t.Run("should exit 0 and say so when every pin is current", func(t *testing.T) {
		t.Parallel()
		// given
		workdir := checkWorkdir(t, currentAnswers())

		// when
		result := run(t, workdir, checkArguments()...)

		// then
		assert.Equal(t, 0, result.exit, result.output())
		assert.Contains(t, result.stdout, "Every pinned dependency is current")
		assert.Contains(t, result.stdout, "Checking 7 pinned dependencies")
		assert.NotContains(t, result.stdout, "EXAMPLECLI", "a major-only pin is current within its major")
		assert.NotContains(t, result.stdout, "HELD", "a pin held inside a major ignores the next")
	})

	t.Run("should exit 1 and name every kind of stale pin", func(t *testing.T) {
		t.Parallel()
		// given
		workdir := checkWorkdir(t, staleAnswers())

		// when
		result := run(t, workdir, checkArguments()...)

		// then
		assert.Equal(t, 1, result.exit)
		for _, name := range []string{"BINARY", "EXAMPLEPKG", "EXAMPLECLI", "someorg/someaction", "digest moved"} {
			assert.Contains(t, result.stdout, name)
		}
		assert.Contains(t, result.stdout, "1.2.3 -> v1.3.0")
		assert.NotContains(t, result.stdout, "HELD")
	})

	t.Run("should exit 1 for a pin with no upstream annotation", func(t *testing.T) {
		t.Parallel()
		// given
		workdir := checkWorkdir(t, currentAnswers())
		manifest := filepath.Join(workdir, "repo", "global", "scripts", "shared", "pinned-versions.sh")
		writeFiles(t, workdir, map[string]string{"repo/global/scripts/shared/pinned-versions.sh": read(t, manifest) +
			"UNTRACKED_PINNED_VERSION=\"9.9.9\"\n"})

		// when
		result := run(t, workdir, checkArguments()...)

		// then
		assert.Equal(t, 1, result.exit)
		assert.Contains(t, result.stdout, "UNTRACKED")
		assert.Contains(t, result.stdout, "no '# upstream:' annotation")
	})

	t.Run("should exit 2 rather than report clean when an upstream cannot be consulted", func(t *testing.T) {
		t.Parallel()
		// given
		workdir := checkWorkdir(t, map[string]any{})

		// when
		result := run(t, workdir, checkArguments()...)

		// then
		assert.Equal(t, 2, result.exit)
		assert.Contains(t, result.stderr, "refusing to report a clean result")
	})

	t.Run("should exit 2 when the advisory database cannot be consulted", func(t *testing.T) {
		t.Parallel()
		// given
		answers := currentAnswers()
		delete(answers, "osv:*")
		workdir := checkWorkdir(t, answers)

		// when
		result := run(t, workdir, checkArguments()...)

		// then
		assert.Equal(t, 2, result.exit, "an advisory that cannot be looked up is never 'no advisories'")
	})

	t.Run("should report without failing under --report-only", func(t *testing.T) {
		t.Parallel()
		// given
		workdir := checkWorkdir(t, staleAnswers())

		// when
		result := run(t, workdir, checkArguments("--report-only")...)

		// then
		assert.Equal(t, 0, result.exit)
		assert.Contains(t, result.stdout, "UPDATE")
	})

	t.Run("should write a JSON and a Markdown report", func(t *testing.T) {
		t.Parallel()
		// given
		workdir := checkWorkdir(t, staleAnswers())

		// when
		run(t, workdir, checkArguments()...)

		// then
		var report map[string]any
		require.NoError(
			t,
			json.Unmarshal([]byte(read(t, filepath.Join(workdir, "out", "dependency-updates.json"))), &report),
		)
		assert.Contains(t, report, "vulnerabilities")
		summary := read(t, filepath.Join(workdir, "out", "dependency-updates.md"))
		assert.Contains(t, summary, "_PINNED_VERSION")
		assert.Contains(t, summary, "commit SHA")
	})

	t.Run("should silence one ignored reference and nothing else", func(t *testing.T) {
		t.Parallel()
		// given
		workdir := checkWorkdir(t, staleAnswers())
		writeFiles(t, workdir, map[string]string{"repo/.dependency-updates.json": `{"ignore": ["someimage*"]}`})

		// when
		result := run(t, workdir, checkArguments()...)

		// then
		assert.NotContains(t, result.stdout, "someimage")
		assert.Contains(t, result.stdout, "otherimage")
		assert.Contains(t, result.stdout, "BINARY")
	})

	t.Run("should refuse a report directory outside the working directory", func(t *testing.T) {
		t.Parallel()
		// given
		workdir := checkWorkdir(t, currentAnswers())

		// when
		result := run(t, workdir, "--repo-dir", "repo", "--report", "../escape", "--fixture", "fixture.json")

		// then
		assert.Equal(t, 1, result.exit)
		assert.Contains(t, result.stderr, "resolves outside the working directory")
		assert.NoDirExists(t, filepath.Join(filepath.Dir(workdir), "escape"))
	})

	t.Run("should refuse a fixture outside the working directory", func(t *testing.T) {
		t.Parallel()
		// given
		workdir := checkWorkdir(t, currentAnswers())

		// when
		result := run(t, workdir, "--repo-dir", "repo", "--report", "out", "--fixture", "/etc/hostname")

		// then
		assert.Equal(t, 1, result.exit)
		assert.Contains(t, result.stderr, "resolves outside the working directory")
	})

	t.Run("should hold a release younger than the cooldown", func(t *testing.T) {
		t.Parallel()
		// given
		answers := currentAnswers()
		answers["github-release:example/binary"] = map[string]any{
			"latest":   "v1.3.0",
			"releases": []any{map[string]any{"version": "v1.3.0", "published": "2026-10-09T00:00:00Z"}},
		}
		workdir := checkWorkdir(t, answers)

		// when
		result := run(t, workdir, checkArguments()...)

		// then
		assert.Equal(t, 0, result.exit, "a release in its cooldown is not yet an update to act on")
		assert.Contains(t, result.stdout, "HELD    BINARY")
	})

	t.Run("should fail while a pin in use has a known vulnerability", func(t *testing.T) {
		t.Parallel()
		// given
		answers := currentAnswers()
		answers["osv:PyPI:examplepkg"] = []any{map[string]any{
			"id": "PYSEC-2026-1", "affected": []any{
				map[string]any{
					"package": map[string]any{"ecosystem": "PyPI", "name": "examplepkg"},
					"ranges": []any{
						map[string]any{"type": "ECOSYSTEM", "events": []any{map[string]any{"introduced": "0"}}},
					},
				},
			},
		}}
		workdir := checkWorkdir(t, answers)

		// when
		result := run(t, workdir, checkArguments()...)

		// then
		assert.Equal(t, 1, result.exit)
		assert.Contains(t, result.stdout, "VULN    EXAMPLEPKG")
		assert.Contains(t, read(t, filepath.Join(workdir, "out", "dependency-updates.md")), "no release fixes it yet")
	})

	t.Run(
		"should check a consumer repository with no manifest and skip a nested pipelines checkout",
		func(t *testing.T) {
			t.Parallel()
			// given
			workdir := t.TempDir()
			writeFiles(t, filepath.Join(workdir, "consumer"), map[string]string{
				".github/workflows/ci.yaml": "jobs:\n  build:\n    steps:\n      - uses: 'someorg/someaction@" + repeat(
					"1",
					40,
				) +
					"' # v3.1.0\n",
				".pipelines/.github/workflows/library.yaml": "      - uses: 'libraryorg/libraryaction@" + repeat(
					"2",
					40,
				) +
					"' # v9.9.9\n",
			})
			writeJSON(t, filepath.Join(workdir, "fixture.json"), currentAnswers())

			// when
			result := run(t, workdir, "--repo-dir", "consumer", "--report", "out", "--fixture", "fixture.json")

			// then
			assert.Equal(t, 0, result.exit, result.output())
			assert.Contains(t, result.stdout, "Checking 1 pinned dependencies")
			assert.NotContains(t, result.stdout, "libraryorg")
		},
	)
}

func TestRealRepositoryCoverage(t *testing.T) {
	t.Parallel()

	t.Run("should find every pin of this repository annotated and every copy in step", func(t *testing.T) {
		t.Parallel()
		// given
		workdir := t.TempDir()
		writeJSON(t, filepath.Join(workdir, "empty.json"), map[string]any{})

		// when
		result := run(t, workdir, "--repo-dir", repositoryRoot(t), "--report", "out", "--fixture", "empty.json")

		// then
		assert.Equal(t, 2, result.exit, "every lookup fails offline, which is what makes the count a coverage figure")
		for _, missing := range []string{"upstream", "asset", "osv"} {
			assert.NotContains(t, result.stdout, "no '# "+missing+":' annotation")
		}
		assert.NotContains(t, result.stdout, "DRIFT")
		var report struct {
			Errors []any `json:"errors"`
		}
		require.NoError(
			t,
			json.Unmarshal([]byte(read(t, filepath.Join(workdir, "out", "dependency-updates.json"))), &report),
		)
		assert.GreaterOrEqual(t, len(report.Errors), 60, "a discovery pattern has stopped matching")
	})

	t.Run("should have run.sh executable", func(t *testing.T) {
		t.Parallel()
		// given
		path := filepath.Join(repositoryRoot(t), "global", "scripts", "tools", "dependency-updates", "run.sh")

		// when
		info, err := os.Stat(path)

		// then
		require.NoError(t, err)
		assert.NotZero(t, info.Mode()&0o100, "run.sh is executable")
	})
}
