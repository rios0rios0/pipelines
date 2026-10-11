package reports

import (
	"fmt"
	"strings"

	"github.com/rios0rios0/pipelines/global/scripts/tools/dependency-updates/internal/domain/commands"
	"github.com/rios0rios0/pipelines/global/scripts/tools/dependency-updates/internal/domain/entities"
)

// digestColumn is how much of a digest the summary's tables show.
const digestColumn = 19

func howToFix() map[entities.Group]string {
	return map[entities.Group]string{
		entities.GroupManifest: "bump the *_PINNED_VERSION (or *_SPEC) in global/scripts/shared/pinned-versions.sh AND " +
			"replace every *_SHA256_* for it from the upstream checksum manifest",
		entities.GroupAction: "re-pin the action to the new release's commit SHA and update its `# vX.Y.Z` comment",
		entities.GroupImage:  "re-resolve the tag's digest and update every `@sha256:` for it",
	}
}

func reportGroups() [][2]string {
	return [][2]string{
		{string(entities.GroupManifest), "Pinned binaries and packages"},
		{string(entities.GroupAction), "GitHub Actions"},
		{string(entities.GroupImage), "Container images"},
	}
}

// Summary is the job summary: what was checked, what is stale, what is known
// to be vulnerable, and what applying did.
func Summary(check commands.CheckResult, apply *commands.ApplyResult) string {
	current := 0
	for _, task := range check.Tasks {
		if !task.Outdated && task.Error == "" {
			current++
		}
	}
	lines := append([]string{"# Dependency update report", ""},
		table("checked", "up to date", "updates available", "known vulnerable", "lookup errors")...)
	lines = append(lines, fmt.Sprintf("| %d | %d | %d | %d | %d |", len(check.Tasks), current, len(check.Outdated()),
		len(check.Vulnerable()), len(check.Failed())), "")
	lines = append(lines, vulnerabilitiesSection(check)...)
	for _, group := range reportGroups() {
		lines = append(lines, outdatedSection(InGroup(check.Outdated(), entities.Group(group[0])),
			entities.Group(group[0]), group[1], apply == nil)...)
	}
	lines = append(lines, rejectedSection(check.Tasks)...)
	lines = append(lines, heldSection(check.Held())...)
	lines = append(lines, driftSection(check.Drift)...)
	lines = append(lines, untrackedSection(check.Untracked)...)
	if apply == nil {
		lines = append(lines, refusedSection(check.Refused())...)
	}
	lines = append(lines, errorsSection(check.Failed(), "")...)
	if check.AdvisoryError != "" {
		lines = append(lines, "## Advisory lookup failed", "",
			"The known-vulnerability database could not be consulted, so nothing on this run is known to be safe:", "",
			"- "+MDSafe(check.AdvisoryError), "")
	}
	if apply != nil {
		lines = append(lines, preparedSection(*apply)...)
	}
	if len(check.Outdated()) == 0 && len(check.Failed()) == 0 && len(check.Drift) == 0 && len(check.Untracked) == 0 &&
		len(check.Vulnerable()) == 0 && len(check.Refused()) == 0 && check.AdvisoryError == "" {
		lines = append(lines, "Every pinned dependency is current.", "")
	}
	return strings.Join(lines, "\n")
}

// vulnerabilitiesSection is what the advisory databases know about the pins in
// use TODAY, whatever happens to them next.
func vulnerabilitiesSection(check commands.CheckResult) []string {
	var rows []string
	for _, task := range SortedTasks(check.Tasks) {
		for _, advisory := range task.Security.Current {
			rows = append(rows, fmt.Sprintf("| `%s` | `%s` | %s | %s | %s |", task.Label, task.Security.Version,
				AdvisoryLink(advisory), advisory.DisplaySeverity(), vulnerabilityStatus(task, advisory)))
		}
		for _, advisory := range task.Security.Accepted {
			rows = append(rows, fmt.Sprintf("| `%s` | `%s` | %s | %s | accepted in `.dependency-updates.json` |",
				task.Label, task.Security.Version, AdvisoryLink(advisory), advisory.DisplaySeverity()))
		}
	}
	if len(rows) == 0 {
		return nil
	}
	lines := append([]string{"## Known vulnerabilities in the pinned versions", "",
		"Running these is the risk this job exists to remove. A fixed release is proposed as soon as one exists -- " +
			"the cooldown does not apply to it -- and the job stays red until it is merged.", ""},
		table("pin", "version", "advisory", "severity", "status")...)
	lines = append(lines, rows...)
	return append(lines, "")
}

func vulnerabilityStatus(task *entities.Task, advisory entities.Advisory) string {
	for _, fixed := range task.Selection.Fixed {
		if fixed.SameIssue(advisory) {
			return "fixed by moving to `" + task.Proposed() + "`"
		}
	}
	return "**no release fixes it yet: needs a person**"
}

func outdatedSection(rows []*entities.Task, group entities.Group, title string, instructions bool) []string {
	if len(rows) == 0 {
		return nil
	}
	lines := []string{fmt.Sprintf("## %s (%d)", title, len(rows)), ""}
	if group == entities.GroupImage {
		lines = append(lines, table("image", "pinned digest", "current digest")...)
		for _, task := range rows {
			lines = append(lines, codeRow(ImageName(task), task.Current[:min(len(task.Current), digestColumn)]+"...",
				MDSafe(task.Latest[:min(len(task.Latest), digestColumn)])+"..."))
		}
	} else {
		lines = append(lines, table("dependency", "pinned", "available", "proposed")...)
		for _, task := range rows {
			proposed := task.Proposed()
			if proposed == "" {
				proposed = "--"
			}
			lines = append(lines, codeRow(task.Label, task.Current, MDSafe(task.Latest), MDSafe(proposed)))
		}
	}
	lines = append(lines, "")
	if instructions {
		lines = append(lines, "To apply: "+howToFix()[group]+".", "")
	}
	return lines
}

func rejectedSection(tasks []*entities.Task) []string {
	var lines []string
	for _, task := range SortedTasks(tasks) {
		for _, rejection := range task.Selection.Rejected {
			if lines == nil {
				lines = []string{"## Releases refused for known advisories", "",
					"A release that would bring in a vulnerability the pin does not already have, or that is a known " +
						"malicious publication, is never proposed; an older safe release is, when one exists.", ""}
			}
			lines = append(
				lines,
				fmt.Sprintf("- `%s` `%s`: %s", task.Label, MDSafe(rejection.Version), MDSafe(rejection.Reason)),
			)
		}
	}
	if lines != nil {
		lines = append(lines, "")
	}
	return lines
}

func driftSection(drift []entities.Drift) []string {
	if len(drift) == 0 {
		return nil
	}
	lines := append([]string{fmt.Sprintf("## Copies that have drifted from the manifest (%d)", len(drift)), ""},
		table("variable", "file", "inline", "manifest")...)
	for _, row := range drift {
		lines = append(lines, codeRow(row.Name, row.File, row.Inline, row.Manifest))
	}
	return append(lines, "")
}

func untrackedSection(untracked []entities.Untracked) []string {
	if len(untracked) == 0 {
		return nil
	}
	lines := []string{fmt.Sprintf("## Pins with no annotation to check them by (%d)", len(untracked)), "",
		"These are not being checked at all. Add the annotation named above each.", ""}
	for _, row := range untracked {
		lines = append(
			lines,
			fmt.Sprintf("- `%s` (pinned `%s`): no `# %s:` annotation", row.Name, row.Current, row.Missing),
		)
	}
	return append(lines, "")
}

// refusedSection is the updates a check alone already knows need a person.
func refusedSection(refused []*entities.Task) []string {
	if len(refused) == 0 {
		return nil
	}
	lines := []string{fmt.Sprintf("## Updates that need a person (%d)", len(refused)), ""}
	for _, task := range SortedTasks(refused) {
		lines = append(lines, bullet(task.Label, MDSafe(task.Refused)))
	}
	return append(lines, "")
}

func preparedSection(apply commands.ApplyResult) []string {
	lines := []string{"## Prepared for the pull request", "",
		fmt.Sprintf("%s applied, %s left for a person.", Plural(len(apply.Applied), "update"),
			Plural(len(apply.Refused), "update")), ""}
	if len(apply.Refused) > 0 {
		for _, task := range SortedTasks(apply.Refused) {
			lines = append(lines, bullet(task.Label, MDSafe(task.Refused)))
		}
		lines = append(lines, "")
	}
	return lines
}
