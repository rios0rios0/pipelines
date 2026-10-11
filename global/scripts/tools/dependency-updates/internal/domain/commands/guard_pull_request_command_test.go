package commands_test

import (
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/rios0rios0/pipelines/global/scripts/tools/dependency-updates/internal/domain/commands"
	"github.com/rios0rios0/pipelines/global/scripts/tools/dependency-updates/internal/domain/entities"
	"github.com/rios0rios0/pipelines/global/scripts/tools/dependency-updates/internal/test/doubles"
)

func guard(pulls *doubles.StubPullRequests) (commands.GuardDecision, error) {
	return commands.NewGuardPullRequestCommand(pulls).
		Execute("owner/repo", "chore/dependency-updates", "main", strings.Repeat("d", 64))
}

func TestGuardPullRequestCommand(t *testing.T) {
	t.Parallel()

	marker := entities.MarkerComment(strings.Repeat("d", 64))
	bot := entities.Commit{SHA: strings.Repeat("a", 40), Parents: 1, Message: "chore(deps): bumped\n\n" +
		entities.FingerprintTrailer + " x"}

	t.Run("should not propose again a set a person declined", func(t *testing.T) {
		t.Parallel()
		// given
		pulls := &doubles.StubPullRequests{Closed: []entities.PullRequest{{Number: 12, Body: marker}}}

		// when
		decision, err := guard(pulls)

		// then
		require.NoError(t, err)
		assert.False(t, decision.Proceed)
		assert.Contains(t, decision.Reason, "declined in #12")
	})

	t.Run("should not count a merged pull request as a decline", func(t *testing.T) {
		t.Parallel()
		// given
		pulls := &doubles.StubPullRequests{
			Closed:      []entities.PullRequest{{Number: 13, Merged: true, Body: marker}},
			MissingHead: true,
		}

		// when
		decision, err := guard(pulls)

		// then
		require.NoError(t, err)
		assert.True(t, decision.Proceed)
	})

	t.Run("should never overwrite a commit a person pushed", func(t *testing.T) {
		t.Parallel()
		// given
		person := entities.Commit{SHA: strings.Repeat("c", 40), Parents: 1, Message: "fix: reverted the yq bump"}
		pulls := &doubles.StubPullRequests{Commits: []entities.Commit{bot, person}}

		// when
		decision, err := guard(pulls)

		// then
		require.NoError(t, err)
		assert.False(t, decision.Proceed)
		assert.Contains(t, decision.Reason, "cccccccccccc")
	})

	t.Run("should treat an 'Update branch' merge commit as the workflow's own", func(t *testing.T) {
		t.Parallel()
		// given
		merge := entities.Commit{SHA: strings.Repeat("b", 40), Parents: 2, Message: "Merge branch 'main'"}
		pulls := &doubles.StubPullRequests{Commits: []entities.Commit{bot, merge}}

		// when
		decision, err := guard(pulls)

		// then
		require.NoError(t, err)
		assert.True(t, decision.Proceed)
	})

	t.Run("should decide nothing when a lookup fails", func(t *testing.T) {
		t.Parallel()
		// given
		pulls := &doubles.StubPullRequests{ClosedErr: errors.New("HTTP 502")}

		// when
		_, err := guard(pulls)

		// then
		require.Error(t, err)
	})
}

func TestRecordChangelogCommand(t *testing.T) {
	t.Parallel()

	head := time.Date(2026, 10, 8, 6, 0, 0, 0, time.UTC)
	entries := []commands.ChangelogEntry{
		{Kind: entities.ChangelogChanged, Body: "bumped things"},
		{Kind: entities.ChangelogSecurity, Body: "fixed GHSA-x"},
	}

	t.Run("should write one chlog fragment per entry, dated by HEAD", func(t *testing.T) {
		t.Parallel()
		// given
		workspace := doubles.NewInMemoryWorkspace(map[string]string{".changes/unreleased/.gitkeep": ""})
		command := commands.NewRecordChangelogCommand(workspace, &doubles.StubHistory{Head: head}, referenceNow())

		// when
		written := command.Execute(entries, strings.Repeat("e", 4)+strings.Repeat("f", 60), time.Time{})

		// then
		assert.Equal(t, ".changes/unreleased/1791439200000000000-eeee.yaml", written)
		assert.Contains(t, workspace.Text(written), "kind: 'Changed'")
		assert.Contains(t, workspace.Text(".changes/unreleased/1791439200000000000-ffff.yaml"), "kind: 'Security'")
	})

	t.Run("should add the entries to a hand-written changelog", func(t *testing.T) {
		t.Parallel()
		// given
		workspace := doubles.NewInMemoryWorkspace(map[string]string{"CHANGELOG.md": "# Changelog\n\n## [Unreleased]\n"})
		command := commands.NewRecordChangelogCommand(workspace, &doubles.StubHistory{Head: head}, referenceNow())

		// when
		written := command.Execute(entries, strings.Repeat("e", 64), time.Time{})

		// then
		assert.Equal(t, "CHANGELOG.md", written)
		assert.Contains(t, workspace.Text("CHANGELOG.md"), "### Changed\n\n- bumped things")
		assert.Contains(t, workspace.Text("CHANGELOG.md"), "### Security\n\n- fixed GHSA-x")
	})

	t.Run("should record nothing in a repository with no changelog", func(t *testing.T) {
		t.Parallel()
		// given
		workspace := doubles.NewInMemoryWorkspace(map[string]string{})
		command := commands.NewRecordChangelogCommand(workspace, &doubles.StubHistory{Head: head}, referenceNow())

		// when
		written := command.Execute(entries, strings.Repeat("e", 64), time.Time{})

		// then
		assert.Empty(t, written)
	})
}
