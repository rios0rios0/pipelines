package reports_test

import (
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/rios0rios0/pipelines/global/scripts/tools/dependency-updates/internal/domain/commands"
	"github.com/rios0rios0/pipelines/global/scripts/tools/dependency-updates/internal/domain/entities"
	"github.com/rios0rios0/pipelines/global/scripts/tools/dependency-updates/internal/infrastructure/reports"
)

func fixingTask() *entities.Task {
	advisory := entities.Advisory{ID: "GHSA-fix", Severity: "CRITICAL"}
	return &entities.Task{
		Group: entities.GroupManifest, Label: "PDM", Kind: entities.KindPyPI, Coord: "pdm", Current: "2.29.0",
		Apply:     &entities.Plan{New: "2.29.2"},
		Security:  entities.SecurityStatus{Checked: true, Version: "2.29.0", Current: []entities.Advisory{advisory}},
		Selection: entities.Selection{Fixed: []entities.Advisory{advisory}, Waived: true},
	}
}

func vendoredTask() *entities.Task {
	return &entities.Task{
		Group: entities.GroupManifest, Label: "GOLANGCI_LINT_CONFIG", Kind: entities.KindGitHubRelease,
		Coord: "maratori/golangci-lint-config", Current: "2.9.0",
		Entry: &entities.ManifestEntry{Coord: "maratori/golangci-lint-config"},
		Apply: &entities.Plan{New: "2.14.0", Vendored: &entities.VendoredPlan{
			Path: "global/scripts/languages/golang/golangci-lint/.golangci.yml", Enabled: []string{"paralleltest"},
			CompareURL: "https://github.com/maratori/golangci-lint-config/compare/v2.9.0...v2.14.0",
		}},
		Security: entities.SecurityStatus{Note: "`# osv: none`: no advisory database covers this artifact"},
	}
}

func TestTitle(t *testing.T) {
	t.Parallel()

	t.Run("should call an update that fixes a known vulnerability a fix", func(t *testing.T) {
		t.Parallel()
		// given / when
		title := reports.Title([]*entities.Task{fixingTask()}, nil)

		// then
		assert.Equal(t, "fix(deps): bumped `PDM` to `2.29.2`, fixing GHSA-fix", title)
	})

	t.Run("should count a routine set of updates as a chore", func(t *testing.T) {
		t.Parallel()
		// given / when
		title := reports.Title([]*entities.Task{vendoredTask(), vendoredTask()}, nil)

		// then
		assert.Equal(t, "chore(deps): bumped 2 pinned dependencies to newer upstream releases", title)
	})
}

func TestChangelogEntries(t *testing.T) {
	t.Parallel()

	t.Run("should record a security fix again under Security", func(t *testing.T) {
		t.Parallel()
		// given / when
		entries := reports.ChangelogEntries([]*entities.Task{fixingTask()}, nil)

		// then
		require.Len(t, entries, 2)
		assert.Equal(t, entities.ChangelogChanged, entries[0].Kind)
		assert.Equal(t, entities.ChangelogSecurity, entries[1].Kind)
		assert.Contains(t, entries[1].Body, "`PDM` to `2.29.2` (GHSA-fix)")
	})
}

func TestPullRequestBody(t *testing.T) {
	t.Parallel()

	t.Run("should show the fix, the waived cooldown and the vendored linter changes", func(t *testing.T) {
		t.Parallel()
		// given
		applied := []*entities.Task{fixingTask(), vendoredTask()}

		// when
		body := reports.PullRequestBody(reports.PullRequestInput{
			Apply: commands.ApplyResult{Applied: applied}, Fingerprint: strings.Repeat("f", 64),
		})

		// then
		assert.Contains(t, body, "## Security (1 known vulnerability fixed)")
		assert.Contains(t, body, "cooldown waived")
		assert.Contains(t, body, "**This changes what every consumer's lint job reports:**")
		assert.Contains(t, body, "switched on: `paralleltest`")
		assert.Contains(t, body, "`# osv: none`: no advisory database covers this artifact")
	})
}

func TestVerification(t *testing.T) {
	t.Parallel()

	t.Run("should state the proof when every change passed", func(t *testing.T) {
		t.Parallel()
		// given
		result := commands.VerifyResult{Changes: []commands.VerifiedChange{
			{
				Label: "PDM",
				From:  "2.29.0",
				To:    "2.29.2",
				Findings: []commands.Finding{
					{Verdict: commands.VerdictPass, Check: commands.CheckAdvisories, Detail: "fixes `GHSA-fix`"},
				},
			},
		}}

		// when
		report := reports.Verification(result)

		// then
		assert.Contains(t, report, reports.VerificationMarker)
		assert.Contains(t, report, "**Verified:**")
		assert.Contains(t, report, "fixes `GHSA-fix`", "code spans in the command's own sentences survive")
	})

	t.Run("should say a change is not verified when a check failed", func(t *testing.T) {
		t.Parallel()
		// given
		result := commands.VerifyResult{Changes: []commands.VerifiedChange{{
			Label: "PDM", Findings: []commands.Finding{{Verdict: commands.VerdictFail, Check: commands.CheckCooldown}},
		}}}

		// when
		report := reports.Verification(result)

		// then
		assert.Contains(t, report, "**Not verified:**")
	})
}

func TestMarkdownSafety(t *testing.T) {
	t.Parallel()

	t.Run("should make an upstream value inert", func(t *testing.T) {
		t.Parallel()
		// given / when
		safe := reports.MDSafe("v1`|[click](https://example.test)<b>x</b>\n# heading")

		// then
		assert.NotContains(t, safe, "[click]")
		assert.NotContains(t, safe, "<b>")
		assert.NotContains(t, safe, "\n")
		assert.NotContains(t, safe, "`")
	})

	t.Run("should keep a sentence's code spans while closing links and HTML", func(t *testing.T) {
		t.Parallel()
		// given / when
		text := reports.MDText("`v1` | [click](x) <b>")

		// then
		assert.Contains(t, text, "`v1`")
		assert.NotContains(t, text, "[click]")
		assert.NotContains(t, text, "<b>")
	})
}
