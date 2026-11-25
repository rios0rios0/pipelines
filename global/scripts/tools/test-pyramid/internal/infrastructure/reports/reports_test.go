package reports_test

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/rios0rios0/pipelines/global/scripts/tools/test-pyramid/internal/domain/entities"
	"github.com/rios0rios0/pipelines/global/scripts/tools/test-pyramid/internal/infrastructure/reports"
)

// worsenedReport is a judgement of one Go suite to which a pull request added two e2e tests.
func worsenedReport() entities.Report {
	target := entities.Counts{entities.TierUnit: 9, entities.TierIntegration: 1}
	pullRequest := entities.Counts{entities.TierUnit: 9, entities.TierIntegration: 1, entities.TierE2E: 2}
	return entities.Report{
		Target: "main",
		Base:   entities.Base{Commit: "0123456789abcdef", Description: `the merge base with "main"`},
		Head:   "fedcba9876543210",
		Policy: entities.DefaultPolicy(),
		Suites: []entities.Suite{{
			Verdict: entities.Judge("go", target, pullRequest, entities.DefaultMix()),
			PullRequest: entities.Classification{Files: []entities.FileTier{
				{Path: "e2e/flow_test.go", Tier: entities.TierE2E, Cases: 2, Reason: "evidence"},
			}},
		}},
	}
}

func TestReports(t *testing.T) {
	t.Parallel()

	t.Run("should write the log with each tier, the shapes and what worsened", func(t *testing.T) {
		t.Parallel()
		// given
		report := worsenedReport()

		// when
		text := reports.Text(report)

		// then
		assert.Contains(t, text, `comparing HEAD (fedcba987654) with the merge base with "main" (0123456789ab)`)
		assert.Contains(
			t,
			text,
			`policy from the defaults (no .test-pyramid on "main"): blocking false, reference mix 80/15/5`,
		)
		assert.Contains(t, text, "  e2e                 0        2       +2\n")
		assert.Contains(t, text, "shape: pyramid on the target branch, hourglass with this pull request")
		assert.Contains(t, text, "WORSENED  functional and e2e tests are now 16.7% of the suite")
	})

	t.Run("should write the summary as a table per suite", func(t *testing.T) {
		t.Parallel()
		// given
		report := worsenedReport()

		// when
		markdown := reports.Markdown(report)

		// then
		assert.Contains(t, markdown, "This pull request **worsens** the test pyramid of: go.")
		assert.Contains(t, markdown, "### `go`: worsens the test pyramid")
		assert.Contains(t, markdown, "| e2e | 0 (0.0%) | 2 (16.7%) | +2 |")
		assert.Contains(t, markdown, "| **total** | 10 | 12 | +2 |")
	})

	t.Run("should write the JSON with the counts, shapes and findings of every suite", func(t *testing.T) {
		t.Parallel()
		// given
		report := worsenedReport()

		// when
		document, err := reports.JSON(report)

		// then
		require.NoError(t, err)
		var decoded struct {
			Verdict string `json:"verdict"`
			Suites  []struct {
				Language    string `json:"language"`
				PullRequest struct {
					E2E   int    `json:"e2e"`
					Shape string `json:"shape"`
				} `json:"pull_request"`
				Findings []string `json:"findings"`
			} `json:"suites"`
		}
		require.NoError(t, json.Unmarshal(document, &decoded))
		assert.Equal(t, "worsened", decoded.Verdict)
		require.Len(t, decoded.Suites, 1)
		assert.Equal(t, 2, decoded.Suites[0].PullRequest.E2E)
		assert.Equal(t, "hourglass", decoded.Suites[0].PullRequest.Shape)
		assert.Len(t, decoded.Suites[0].Findings, 1)
	})

	t.Run("should write every file's decision as tab-separated values", func(t *testing.T) {
		t.Parallel()
		// given
		classification := worsenedReport().Suites[0].PullRequest

		// when
		tsv := reports.Classification(classification)

		// then
		assert.Equal(t, "tier\tcases\treason\tpath\ne2e\t2\tevidence\te2e/flow_test.go\n", tsv)
	})

	t.Run("should write every report into the directory", func(t *testing.T) {
		t.Parallel()
		// given
		directory := filepath.Join(t.TempDir(), "test-pyramid")

		// when
		summary, err := reports.Write(worsenedReport(), directory)

		// then
		require.NoError(t, err)
		assert.Equal(t, filepath.Join(directory, "summary.md"), summary)
		for _, name := range []string{"summary.md", "test-pyramid.json", "go-target.tsv", "go-pull-request.tsv"} {
			assert.FileExists(t, filepath.Join(directory, name))
		}
	})

	t.Run("should make a name from outside inert before it reaches markup", func(t *testing.T) {
		t.Parallel()
		// given
		name := "feat/x`<b>|y%0A"

		// when
		inert := reports.Inert(name)

		// then
		assert.Equal(t, "feat/x??b??y?0A", inert)
	})
}

func TestPlatform(t *testing.T) {
	t.Parallel()

	environment := func(values map[string]string) func(string) string {
		return func(name string) string { return values[name] }
	}

	t.Run("should annotate the run on GitHub Actions", func(t *testing.T) {
		t.Parallel()
		// given
		platform := reports.DetectPlatform(environment(map[string]string{"GITHUB_ACTIONS": "true"}))
		var stdout bytes.Buffer

		// when
		platform.Annotate(&stdout, "warning", "worsens go\n::error::forged")

		// then
		assert.Equal(t, "::warning title=Test pyramid::worsens go?::error::forged\n", stdout.String())
	})

	t.Run("should log an issue on Azure DevOps", func(t *testing.T) {
		t.Parallel()
		// given
		platform := reports.DetectPlatform(environment(map[string]string{"TF_BUILD": "True"}))
		var stdout bytes.Buffer

		// when
		platform.Annotate(&stdout, "error", "worsens go")

		// then
		assert.Equal(t, "##vso[task.logissue type=error]worsens go\n", stdout.String())
	})

	t.Run("should annotate nothing where the platform has no annotations", func(t *testing.T) {
		t.Parallel()
		// given
		platform := reports.DetectPlatform(environment(map[string]string{"GITLAB_CI": "true"}))
		var stdout bytes.Buffer

		// when
		platform.Annotate(&stdout, "warning", "worsens go")

		// then
		assert.Empty(t, stdout.String())
	})

	t.Run("should append the summary to GitHub's job summary", func(t *testing.T) {
		t.Parallel()
		// given
		directory := t.TempDir()
		summary, stepSummary := filepath.Join(directory, "summary.md"), filepath.Join(directory, "step-summary")
		require.NoError(t, os.WriteFile(summary, []byte("## Test pyramid\n"), 0o600))
		require.NoError(t, os.WriteFile(stepSummary, []byte("earlier\n"), 0o600))
		platform := reports.DetectPlatform(environment(map[string]string{
			"GITHUB_ACTIONS": "true", "GITHUB_STEP_SUMMARY": stepSummary,
		}))

		// when
		err := platform.PublishSummary(&bytes.Buffer{}, summary)

		// then
		require.NoError(t, err)
		content, readErr := os.ReadFile(stepSummary)
		require.NoError(t, readErr)
		assert.Equal(t, "earlier\n## Test pyramid\n", string(content))
	})

	t.Run("should upload the summary to the Azure DevOps run", func(t *testing.T) {
		t.Parallel()
		// given
		platform := reports.DetectPlatform(environment(map[string]string{"TF_BUILD": "True"}))
		var stdout bytes.Buffer

		// when
		err := platform.PublishSummary(&stdout, "/work/build/reports/test-pyramid/summary.md")

		// then
		require.NoError(t, err)
		assert.Equal(t, "##vso[task.uploadsummary]/work/build/reports/test-pyramid/summary.md\n", stdout.String())
	})
}
