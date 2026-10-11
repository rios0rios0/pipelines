package commands

import (
	"time"

	"github.com/rios0rios0/pipelines/global/scripts/tools/dependency-updates/internal/domain/entities"
	"github.com/rios0rios0/pipelines/global/scripts/tools/dependency-updates/internal/domain/repositories"
)

// ChangelogEntry is one line a change is recorded under.
type ChangelogEntry struct {
	Kind string
	Body string
}

// RecordChangelogCommand records a change the way the repository records
// changes: a chlog fragment when it uses chlog, otherwise an entry under
// `## [Unreleased]` of its CHANGELOG.md.
type RecordChangelogCommand struct {
	workspace repositories.WorkspaceRepository
	history   repositories.HistoryRepository
	now       time.Time
}

// NewRecordChangelogCommand builds the recorder; `now` is the fallback when the
// repository has no history to date the entry from.
func NewRecordChangelogCommand(
	workspace repositories.WorkspaceRepository, history repositories.HistoryRepository, now time.Time,
) *RecordChangelogCommand {
	return &RecordChangelogCommand{workspace: workspace, history: history, now: now}
}

// Execute writes the entries and returns where the first went, or "" when the
// repository has nowhere to record them. `explicit`, when set, dates them.
func (c *RecordChangelogCommand) Execute(entries []ChangelogEntry, fingerprint string, explicit time.Time) string {
	if len(entries) == 0 {
		return ""
	}
	when := c.entryTime(explicit)
	if c.workspace.IsFile(".chlog.yaml") || c.workspace.IsFile(".chlog.yml") ||
		c.workspace.IsDir(".changes/unreleased") {
		first := ""
		for slot, entry := range entries {
			name := entities.FragmentName(when, fingerprint, slot)
			c.workspace.Set(name, entities.FragmentContent(entry.Kind, entry.Body, when))
			if first == "" {
				first = name
			}
		}
		return first
	}
	const changelog = "CHANGELOG.md"
	if !c.workspace.IsFile(changelog) {
		return ""
	}
	text := c.workspace.Text(changelog)
	for _, entry := range entries {
		updated, found := entities.InsertUnreleasedEntry(text, entry.Kind, entry.Body)
		if !found {
			return ""
		}
		text = updated
	}
	if !c.workspace.Set(changelog, text) {
		return ""
	}
	return changelog
}

// entryTime is when the entry says it was written: the time of the commit the
// branch is built on, not of the run. A rerun against an unchanged default
// branch then writes byte-identical files, so the pull request is not
// force-pushed -- and its approvals are not dismissed -- for no change at all.
func (c *RecordChangelogCommand) entryTime(explicit time.Time) time.Time {
	when := explicit
	if when.IsZero() {
		if head, err := c.history.HeadCommitTime(); err == nil {
			when = head
		} else {
			when = c.now
		}
	}
	return when.UTC().Truncate(time.Second)
}
