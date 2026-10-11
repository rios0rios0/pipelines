package reports

import (
	"fmt"
	"slices"
	"strings"
	"time"

	"github.com/rios0rios0/pipelines/global/scripts/tools/dependency-updates/internal/domain/commands"
	"github.com/rios0rios0/pipelines/global/scripts/tools/dependency-updates/internal/domain/entities"
)

// knownVulnerabilities is how the pull request counts advisories.
const knownVulnerabilities = "known vulnerabilities"

// maxBodyLength keeps the body under GitHub's 65536-character limit. Far beyond
// any real run, but a truncated body beats a pull request that cannot be opened.
const maxBodyLength = 60000

const (
	intro = "Every pin below has a newer release upstream than the one this repository runs. The scheduled " +
		"`Dependency Updates` workflow resolved each new value from the release itself, checked it against the " +
		"known-vulnerability and malicious-package databases, and opened this pull request; nothing here is merged " +
		"until a person decides to."
	actionsNote = "Every `uses:` of each action, sub-path actions included, is re-pinned to the commit its release " +
		"tag points at, with the comment moved to the new version. That commit descends from the one pinned today; " +
		"the history column links the diff to read."
	imagesNote = "Same tag, new digest: the image was rebuilt upstream under the tag this repository already uses, " +
		"which is almost always a base-image security refresh. Each rebuild was scanned against the image it " +
		"replaces -- exported straight from the registry, every layer verified against its digest, and scanned with " +
		"OSV-Scanner -- and none introduces a known vulnerability. Moving to a different tag stays a decision this " +
		"workflow never makes."
	toolsNote = "Each digest describes the asset of the NEW version: the `# asset:` template that located it first " +
		"reproduced the committed digest of the current one, which is what proves it names the file the installer " +
		"verifies."
	errorsNote = "These could not be checked at all on this run, so they are neither proposed nor known to be current:"
	checksNote = "No checks on this pull request? It was opened with the default `GITHUB_TOKEN`, and GitHub does not " +
		"let that token start workflows. Close and reopen the pull request to run them, or give the workflow a " +
		"`dependency_updates_token`: a personal access token's pull requests do start them."
	truncated = "\n\n*Truncated: see the workflow run's job summary for the full report.*\n"
)

func deciding() []string {
	return []string{
		"- **Merge** to take every update above.",
		"- **Close** to decline this set: the workflow does not propose it again, and opens a new pull request " +
			"only once upstream releases something newer.",
		"- **Stop tracking** one dependency for good by adding its name to `.dependency-updates.json` " +
			"(`{\"ignore\": [\"actions/checkout\"]}`).",
		"- **Edit** freely: a commit pushed to this branch by hand is never overwritten. The workflow stops " +
			"updating the branch until the pull request is merged or closed.",
	}
}

// Title is the pull request's title and the commit's subject. An update that
// fixes a known vulnerability is a `fix`, so it reads as one in every list it
// appears in.
func Title(applied []*entities.Task, fixes []entities.CopyChange) string {
	kind := "chore"
	if countFixed(applied) > 0 {
		kind = "fix"
	}
	if len(applied) == 1 && len(fixes) == 0 {
		task := applied[0]
		if task.Group == entities.GroupImage {
			return fmt.Sprintf("%s(deps): re-pinned `%s` to the digest its tag resolves to now", kind, task.Label)
		}
		title := fmt.Sprintf("%s(deps): bumped `%s` to `%s`", kind, task.Label, task.Apply.New)
		if fixed := task.Selection.Fixed; len(fixed) > 0 {
			title += ", fixing " + strings.Join(entities.AdvisoryIDs(fixed), ", ")
		}
		return title
	}
	if len(applied) > 0 {
		title := fmt.Sprintf("%s(deps): bumped %s to newer upstream releases", kind,
			Plural(len(applied), "pinned dependency", "pinned dependencies"))
		if fixed := countFixed(applied); fixed > 0 {
			title += ", fixing " + Plural(fixed, "known vulnerability", knownVulnerabilities)
		}
		return title
	}
	if len(fixes) > 0 {
		return fmt.Sprintf("chore(deps): realigned %s with `pinned-versions.sh`", copiesPhrase(len(fixes)))
	}
	return "chore(deps): every pinned dependency is current"
}

// changeList is `label` `new` pairs for one group; with `moves`, `label` `old`
// -> `new`, as a hand-written bump reads.
func changeList(applied []*entities.Task, group entities.Group, moves bool) string {
	rows := InGroup(applied, group)
	described := make([]string, 0, len(rows))
	for _, task := range rows {
		switch {
		case group == entities.GroupImage:
			described = append(described, "`"+task.Label+"`")
		case moves:
			described = append(described, fmt.Sprintf("`%s` `%s` -> `%s`", task.Label, task.Current, task.Apply.New))
		default:
			described = append(described, fmt.Sprintf("`%s` `%s`", task.Label, task.Apply.New))
		}
	}
	return strings.Join(described, ", ")
}

func copiesClause(fixes []entities.CopyChange) string {
	clause := fmt.Sprintf("kept %s in step with `pinned-versions.sh`", copiesPhrase(len(fixes)))
	drifted := 0
	for _, fix := range fixes {
		if fix.Drifted {
			drifted++
		}
	}
	if drifted > 0 {
		clause += fmt.Sprintf(" (%d of them already out of step before this change)", drifted)
	}
	return clause
}

// ChangelogEntries are the lines the change is recorded under: the bumps as
// `Changed`, and -- when any of them fixes a known vulnerability -- the fixes
// again as `Security`, where a reader of the changelog looks for them.
func ChangelogEntries(applied []*entities.Task, fixes []entities.CopyChange) []commands.ChangelogEntry {
	var clauses []string
	for _, noun := range groupNouns() {
		rows := InGroup(applied, entities.Group(noun[0]))
		if len(rows) == 0 {
			continue
		}
		clause := fmt.Sprintf(
			"%s (%s)",
			Plural(len(rows), noun[1]),
			changeList(applied, entities.Group(noun[0]), false),
		)
		if slices.ContainsFunc(rows, func(task *entities.Task) bool { return len(task.Apply.Digests) > 0 }) {
			clause += ", each binary's new SHA-256 taken from its release asset"
		}
		clauses = append(clauses, clause)
	}
	body := ""
	if len(clauses) > 0 {
		body = "bumped the pinned dependencies the scheduled `Dependency Updates` workflow found outdated: " + Joined(
			clauses,
		)
	}
	if len(fixes) > 0 {
		if body != "" {
			body += "; " + copiesClause(fixes)
		} else {
			body = copiesClause(fixes)
		}
	}
	var entries []commands.ChangelogEntry
	if body != "" {
		entries = append(entries, commands.ChangelogEntry{Kind: entities.ChangelogChanged, Body: body})
	}
	if fixing := fixedAdvisories(applied); len(fixing) > 0 {
		described := make([]string, 0, len(fixing))
		for _, task := range fixing {
			described = append(described, fmt.Sprintf("`%s` to `%s` (%s)", task.Label, task.Apply.New,
				strings.Join(entities.AdvisoryIDs(task.Selection.Fixed), ", ")))
		}
		entries = append(entries, commands.ChangelogEntry{
			Kind: entities.ChangelogSecurity,
			Body: "fixed known vulnerabilities in pinned dependencies by bumping " + Joined(described),
		})
	}
	return entries
}

// CommitMessage is the update commit's message, carrying the fingerprint
// trailer the branch guard recognises.
func CommitMessage(applied []*entities.Task, fixes []entities.CopyChange, fingerprint string) string {
	lines := []string{Title(applied, fixes), ""}
	if len(InGroup(applied, entities.GroupAction)) > 0 {
		lines = append(lines, "- bumped GitHub Actions: "+changeList(applied, entities.GroupAction, true))
	}
	if images := InGroup(applied, entities.GroupImage); len(images) > 0 {
		lines = append(lines, fmt.Sprintf("- re-resolved %s: %s", Plural(len(images), "image digest"),
			changeList(applied, entities.GroupImage, false)))
	}
	if len(InGroup(applied, entities.GroupManifest)) > 0 {
		lines = append(
			lines,
			"- bumped tool pins with their checksums: "+changeList(applied, entities.GroupManifest, true),
		)
	}
	for _, task := range InGroup(applied, entities.GroupManifest) {
		if task.Apply.Vendored != nil {
			lines = append(lines, fmt.Sprintf("- re-merged this repository's adjustments to `%s` onto `%s` `%s`",
				task.Apply.Vendored.Path, task.Entry.Coord, task.Apply.New))
		}
	}
	for _, task := range fixedAdvisories(applied) {
		lines = append(
			lines,
			fmt.Sprintf("- fixed %s in `%s`", strings.Join(entities.AdvisoryIDs(task.Selection.Fixed), ", "),
				task.Label),
		)
	}
	if len(fixes) > 0 {
		lines = append(lines, "- "+copiesClause(fixes))
	}
	lines = append(lines, "", entities.FingerprintTrailer+" "+fingerprint)
	return strings.Join(lines, "\n") + "\n"
}

// PullRequestInput is everything the body is rendered from.
type PullRequestInput struct {
	Check       commands.CheckResult
	Apply       commands.ApplyResult
	Fingerprint string
	Changelog   string
}

// PullRequestBody is the pull request's description.
func PullRequestBody(input PullRequestInput) string {
	applied := input.Apply.Applied
	lines := []string{entities.MarkerComment(input.Fingerprint), "", intro, "",
		"**Proposed: " + SummaryPhrase(applied, input.Apply.Fixes) + ".**", ""}
	sections := [][]string{
		securitySection(applied),
		actionsSection(applied),
		imagesSection(applied),
		toolsSection(applied),
		vendoredSection(applied),
		verificationSection(applied),
		copiesSection(input.Apply.Fixes),
		needsPersonSection(input.Check, input.Apply),
		heldSection(input.Check.Held()),
		errorsSection(input.Check.Failed(), errorsNote),
		decidingSection(input.Changelog),
	}
	for _, section := range sections {
		lines = append(lines, section...)
	}
	body := strings.Join(lines, "\n") + "\n"
	if len(body) > maxBodyLength {
		body = body[:maxBodyLength] + truncated
	}
	return body
}

func securitySection(applied []*entities.Task) []string {
	fixing := fixedAdvisories(applied)
	if len(fixing) == 0 {
		return nil
	}
	lines := []string{fmt.Sprintf("## Security (%s fixed)", Plural(countFixed(applied), "known vulnerability",
		knownVulnerabilities)), "", "These pins run a release with a published advisory today. Merging removes it."}
	lines = append(lines, "")
	for _, task := range fixing {
		line := fmt.Sprintf("- `%s` `%s` -> `%s` fixes %s", task.Label, task.Current, task.Apply.New,
			AdvisoryList(task.Selection.Fixed))
		if task.Selection.Waived {
			line += " (cooldown waived: the fix is newer than the cooldown, and running a known vulnerability is the larger risk)"
		}
		lines = append(lines, line)
	}
	return append(lines, "")
}

func actionsSection(applied []*entities.Task) []string {
	actions := InGroup(applied, entities.GroupAction)
	if len(actions) == 0 {
		return nil
	}
	lines := append([]string{fmt.Sprintf("## GitHub Actions (%d)", len(actions)), ""},
		table("action", "pinned", "proposed", "history", "")...)
	for _, task := range actions {
		plan := task.Apply
		history := "first pin"
		if plan.History != nil {
			history = fmt.Sprintf("%s ahead, %s ([diff](%s))", Plural(plan.History.AheadBy, "commit"),
				Plural(plan.History.Files, "file"), plan.History.CompareURL)
		}
		lines = append(
			lines,
			fmt.Sprintf("| [`%s`](%s) | `%s` | `%s` (`%s`) | %s | %s |", task.Label, ReleaseLink(task),
				task.Current, plan.New, plan.SHA[:shortDigestLength], history, majorMark(task.Current, plan.New)),
		)
	}
	return append(lines, "", actionsNote, "")
}

func imagesSection(applied []*entities.Task) []string {
	images := InGroup(applied, entities.GroupImage)
	if len(images) == 0 {
		return nil
	}
	lines := append([]string{fmt.Sprintf("## Container images (%d)", len(images)), ""},
		table("image", "pinned digest", "proposed digest", knownVulnerabilities)...)
	for _, task := range images {
		lines = append(lines, fmt.Sprintf("| `%s` | `%s` | `%s` | %s |", task.Label, ShortDigest(task.Current),
			ShortDigest(task.Apply.New), imageNote(task.Apply.Image)))
	}
	return append(lines, "", imagesNote, "")
}

// imageNote is what scanning a rebuild found, for the image table.
func imageNote(scan *entities.ImagePlan) string {
	const listed = 3
	switch {
	case scan == nil:
		return "not scanned: image scanning is switched off"
	case scan.Skipped != "":
		return "not scanned: " + MDText(scan.Skipped)
	case len(scan.Fixed) > 0:
		return fmt.Sprintf(
			"introduces none; fixes %d: %s",
			len(scan.Fixed),
			MDText(entities.DescribeFindings(scan.Fixed, listed)),
		)
	default:
		return fmt.Sprintf("introduces none; %d known in both", scan.Known)
	}
}

func checksumNote(plan *entities.Plan) string {
	if len(plan.Digests) > 0 {
		var sources []string
		for _, digest := range plan.Digests {
			if !slices.Contains(sources, digest.Source) {
				sources = append(sources, digest.Source)
			}
		}
		slices.Sort(sources)
		return Plural(len(plan.Digests), "digest") + ": " + strings.Join(sources, "; ")
	}
	if entities.IsMajorOnly(plan.New) {
		return fmt.Sprintf("a major-only range: the newest `%s.x` is installed from its registry", plan.New)
	}
	return "installed by exact version from its registry"
}

func toolsSection(applied []*entities.Task) []string {
	tools := InGroup(applied, entities.GroupManifest)
	if len(tools) == 0 {
		return nil
	}
	lines := append([]string{fmt.Sprintf("## Tools and packages (%d)", len(tools)), ""},
		table("pin", "pinned", "proposed", "checksums")...)
	for _, task := range tools {
		label := "`" + task.Label + "`"
		if link := ReleaseLink(task); link != "" {
			label = fmt.Sprintf("[`%s`](%s)", task.Label, link)
		}
		if mark := majorMark(task.Current, task.Apply.New); mark != "" {
			label += " " + mark
		}
		lines = append(
			lines,
			fmt.Sprintf("| %s | `%s` | `%s` | %s |", label, task.Current, task.Apply.New, checksumNote(task.Apply)),
		)
	}
	return append(lines, "", toolsNote, "")
}

func vendoredSection(applied []*entities.Task) []string {
	var lines []string
	for _, task := range InGroup(applied, entities.GroupManifest) {
		vendored := task.Apply.Vendored
		if vendored == nil {
			continue
		}
		if lines == nil {
			lines = []string{"## Vendored files", ""}
		}
		lines = append(
			lines,
			fmt.Sprintf("`%s` is `%s` with this repository's adjustments on top. They were re-applied to "+
				"`%s` with a three-way merge from the upstream file the copy was taken from, whose SHA-256 is committed; "+
				"[upstream's diff](%s).", vendored.Path, task.Entry.Coord, task.Apply.New, vendored.CompareURL),
			"",
		)
		if len(vendored.Enabled)+len(vendored.Disabled) == 0 {
			lines = append(lines, "No linter is switched on or off.", "")
			continue
		}
		lines = append(lines, "**This changes what every consumer's lint job reports:**", "")
		if len(vendored.Enabled) > 0 {
			lines = append(lines, "- switched on: "+quotedList(vendored.Enabled))
		}
		if len(vendored.Disabled) > 0 {
			lines = append(lines, "- switched off: "+quotedList(vendored.Disabled))
		}
		lines = append(lines, "")
	}
	return lines
}

func quotedList(names []string) string {
	quoted := make([]string, 0, len(names))
	for _, name := range names {
		quoted = append(quoted, "`"+name+"`")
	}
	return strings.Join(quoted, ", ")
}

// verificationSection is the evidence for each update that is not already in
// its own table: how old the release is, and what is known about it.
func verificationSection(applied []*entities.Task) []string {
	var rows []*entities.Task
	for _, task := range SortedTasks(applied) {
		if task.Group != entities.GroupImage {
			rows = append(rows, task)
		}
	}
	if len(rows) == 0 {
		return nil
	}
	lines := append([]string{"## Verification", "",
		"Every release below was checked against OSV.dev -- GitHub's reviewed and malware advisories, the OpenSSF " +
			"malicious-packages feed, the Go vulnerability database, PyPA and RubySec -- and none introduces an " +
			"advisory the pin does not already have.", ""}, table("dependency", "release age", "known advisories")...)
	for _, task := range rows {
		lines = append(
			lines,
			fmt.Sprintf("| `%s` `%s` | %s | %s |", task.Label, task.Apply.New, ageNote(task), advisoryNote(task)),
		)
	}
	return append(lines, "")
}

func ageNote(task *entities.Task) string {
	target := task.Selection.Target
	switch {
	case target == nil || target.Published.IsZero():
		return "not dated by its registry"
	case target.Published.Unix() == 0:
		return "old enough for any cooldown"
	case task.Selection.Waived:
		return "published " + target.Published.Format(time.DateOnly) + "; cooldown waived to fix a known vulnerability"
	default:
		return "published " + target.Published.Format(time.DateOnly)
	}
}

func advisoryNote(task *entities.Task) string {
	switch {
	case !task.Security.Checked:
		return MDText(task.Security.Note)
	case len(task.Selection.Fixed) > 0 && len(task.Selection.Remaining) > 0:
		return "fixes " + AdvisoryList(
			task.Selection.Fixed,
		) + "; still affected by " + AdvisoryList(
			task.Selection.Remaining,
		)
	case len(task.Selection.Fixed) > 0:
		return "fixes " + AdvisoryList(task.Selection.Fixed)
	case len(task.Selection.Remaining) > 0:
		return "still affected by " + AdvisoryList(task.Selection.Remaining) + " (not introduced by this release)"
	default:
		return "none known"
	}
}

func copiesSection(fixes []entities.CopyChange) []string {
	if len(fixes) == 0 {
		return nil
	}
	sorted := slices.Clone(fixes)
	slices.SortStableFunc(sorted, func(left, right entities.CopyChange) int {
		if order := strings.Compare(left.File, right.File); order != 0 {
			return order
		}
		return strings.Compare(left.Var, right.Var)
	})
	lines := append([]string{fmt.Sprintf("## Inline copies kept in step (%d)", len(fixes)), ""},
		table("file", "mirrors", "from", "to")...)
	for _, fix := range sorted {
		show := func(value string) string { return value }
		if entities.IsDigestVar(fix.Var) {
			show = ShortDigest
		}
		note := ""
		if fix.Drifted {
			note = " (was already out of step)"
		}
		lines = append(
			lines,
			fmt.Sprintf("| `%s` | `%s` | `%s`%s | `%s` |", fix.File, fix.Var, show(fix.From), note, show(fix.To)),
		)
	}
	return append(lines, "")
}

// needsPersonSection is everything this pull request cannot carry: refused
// updates, pins nothing can check, and known vulnerabilities no release fixes.
func needsPersonSection(check commands.CheckResult, apply commands.ApplyResult) []string {
	unfixed := unfixedVulnerabilities(check.Tasks)
	total := len(apply.Refused) + len(check.Untracked) + len(unfixed)
	if total == 0 {
		return nil
	}
	lines := []string{fmt.Sprintf("## Not in this pull request: needs a person (%d)", total), ""}
	for _, task := range SortedTasks(apply.Refused) {
		lines = append(lines, fmt.Sprintf("- `%s` `%s` -> `%s`: %s", task.Label, shown(task, task.Current),
			MDSafe(shown(task, task.Target())), MDSafe(task.Refused)))
	}
	for _, task := range unfixed {
		lines = append(lines, fmt.Sprintf("- `%s` `%s` is affected by %s and no release this run could adopt fixes it",
			task.Label, task.Current, AdvisoryList(task.Selection.Remaining)))
	}
	for _, row := range check.Untracked {
		lines = append(
			lines,
			bullet(row.Name, fmt.Sprintf("no `# %s:` annotation, so it is not being checked", row.Missing)),
		)
	}
	return append(lines, "")
}

// unfixedVulnerabilities are the vulnerable pins whose proposal, if any, leaves
// an advisory in place.
func unfixedVulnerabilities(tasks []*entities.Task) []*entities.Task {
	var unfixed []*entities.Task
	for _, task := range SortedTasks(tasks) {
		if task.IsVulnerable() && len(task.Selection.Remaining) > 0 {
			unfixed = append(unfixed, task)
		}
	}
	return unfixed
}

func heldSection(held []*entities.Task) []string {
	if len(held) == 0 {
		return nil
	}
	lines := []string{fmt.Sprintf("## Held by the cooldown (%d)", len(held)), "",
		"Newer releases that are too young to adopt. Most supply-chain compromises are found and pulled within days; " +
			"these are proposed once they have been public for the cooldown.", ""}
	for _, task := range SortedTasks(held) {
		release := task.Selection.Held
		when := "an unknown date, so the cooldown cannot be shown to have passed"
		if !release.Published.IsZero() {
			when = release.Published.Format(time.DateOnly)
		}
		lines = append(lines, fmt.Sprintf("- `%s` `%s` (published %s)", task.Label, MDSafe(release.Version), when))
	}
	return append(lines, "")
}

func errorsSection(failed []*entities.Task, preamble string) []string {
	if len(failed) == 0 {
		return nil
	}
	lines := []string{fmt.Sprintf("## Lookup errors (%d)", len(failed)), ""}
	if preamble != "" {
		lines = append(lines, preamble, "")
	}
	for _, task := range failed {
		lines = append(lines, bullet(task.Label, MDSafe(task.Error)))
	}
	return append(lines, "")
}

func decidingSection(changelog string) []string {
	lines := append([]string{"## Deciding", ""}, deciding()...)
	lines = append(lines, "")
	if changelog != "" {
		lines = append(lines, "The change is recorded in `"+changelog+"`.", "")
	}
	return append(lines, checksNote)
}
