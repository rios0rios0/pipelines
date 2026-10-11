// Package reports renders what a run found and did: the job summary, the pull
// request's title, body and commit message, the changelog entries, the console
// lines and the JSON report.
package reports

import (
	"fmt"
	"regexp"
	"slices"
	"strings"
	"unicode/utf8"

	"github.com/rios0rios0/pipelines/global/scripts/tools/dependency-updates/internal/domain/entities"
)

const (
	// mdSafeLimit is how much of an upstream-supplied string a page shows.
	mdSafeLimit = 300
	// shortDigestLength is how much of a digest or SHA a table shows.
	shortDigestLength = 12
)

// unsafeMarkdown is everything that can leave a code span or a table cell, open
// a link, or start HTML.
var unsafeMarkdown = regexp.MustCompile("[`|<>\\[\\]\r\n]")

// MDSafe makes an UPSTREAM-supplied string inert for a Markdown page.
//
// Release names reach the job summary and the pull request body, both rendered
// as Markdown, so a tag or a refusal quoting one could otherwise carry a link,
// an image or a broken table into a page a person is reading in order to decide
// what to trust. Values validated before being applied never need this;
// anything shown BECAUSE it was refused does. Underscores are left alone: asset
// names are full of them, and mangling those would make a refusal unreadable
// without making it any safer.
func MDSafe(value string) string {
	cleaned := unsafeMarkdown.ReplaceAllString(value, "?")
	if utf8.RuneCountInString(cleaned) <= mdSafeLimit {
		return cleaned
	}
	return string([]rune(cleaned)[:mdSafeLimit]) + "..."
}

// textEscaper neutralises what could open a link, start HTML, end a table
// cell or begin a new block, and leaves code spans alone.
func textEscaper() *strings.Replacer {
	return strings.NewReplacer("|", `\|`, "<", "&lt;", ">", "&gt;", "[", `\[`, "]", `\]`, "\r", " ", "\n", " ")
}

// MDText is this command's OWN sentence -- which may quote a version, a URL or
// an error from upstream -- made safe for a Markdown page while keeping the
// code spans it was written with. A raw upstream value shown on its own goes
// through MDSafe instead.
func MDText(value string) string {
	return textEscaper().Replace(value)
}

// ShortDigest is a digest as a table shows it.
func ShortDigest(digest string) string {
	trimmed := strings.ReplaceAll(digest, "sha256:", "")
	return trimmed[:min(len(trimmed), shortDigestLength)]
}

func shown(task *entities.Task, value string) string {
	if task.Group == entities.GroupImage {
		return ShortDigest(value)
	}
	return value
}

// Plural is `1 file`, `2 files`.
func Plural(count int, singular string, many ...string) string {
	word := singular
	if count != 1 {
		word = singular + "s"
		if len(many) > 0 {
			word = many[0]
		}
	}
	return fmt.Sprintf("%d %s", count, word)
}

func copiesPhrase(count int) string {
	return Plural(count, "inline copy", "inline copies")
}

// Joined is `a`, `a and b`, `a, b and c`.
func Joined(words []string) string {
	switch len(words) {
	case 0:
		return ""
	case 1:
		return words[0]
	default:
		return strings.Join(words[:len(words)-1], ", ") + " and " + words[len(words)-1]
	}
}

func table(columns ...string) []string {
	return []string{"| " + strings.Join(columns, " | ") + " |", "|" + strings.Repeat("---|", len(columns))}
}

func codeRow(cells ...string) string {
	quoted := make([]string, 0, len(cells))
	for _, cell := range cells {
		quoted = append(quoted, "`"+cell+"`")
	}
	return "| " + strings.Join(quoted, " | ") + " |"
}

func bullet(label, text string) string {
	return "- `" + label + "`: " + text
}

func majorMark(current, proposed string) string {
	if entities.IsMajor(current, proposed) {
		return "**major**"
	}
	return ""
}

// releasePages is where a person reads what changed in a release, by kind.
func releasePages() map[string]string {
	return map[string]string{
		entities.KindGitHubRelease: "https://github.com/%s/releases/tag/%s",
		entities.KindGitHubTag:     "https://github.com/%s/releases/tag/%s",
		entities.KindGitLabTag:     "https://gitlab.com/%s/-/tags/%s",
		entities.KindPyPI:          "https://pypi.org/project/%s/%s/",
		entities.KindNpm:           "https://www.npmjs.com/package/%s/v/%s",
		entities.KindRubyGems:      "https://rubygems.org/gems/%s/versions/%s",
		entities.KindGoProxy:       "https://pkg.go.dev/%s@%s",
	}
}

// ReleaseLink is the page describing the release a task moves to.
func ReleaseLink(task *entities.Task) string {
	page, known := releasePages()[task.Kind]
	if !known || task.Group == entities.GroupImage {
		return ""
	}
	return fmt.Sprintf(page, task.Coord, task.Target())
}

// AdvisoryLink is an advisory's page.
func AdvisoryLink(advisory entities.Advisory) string {
	return fmt.Sprintf("[%s](https://osv.dev/vulnerability/%s)", advisory.ID, advisory.ID)
}

// AdvisoryList is `GHSA-x (HIGH), MAL-y (MALICIOUS)`, linked.
func AdvisoryList(advisories []entities.Advisory) string {
	described := make([]string, 0, len(advisories))
	for _, advisory := range advisories {
		described = append(described, AdvisoryLink(advisory)+" ("+advisory.DisplaySeverity()+")")
	}
	return strings.Join(described, ", ")
}

// groupNouns are what each group's updates are called when they are counted.
func groupNouns() [][2]string {
	return [][2]string{
		{string(entities.GroupAction), "GitHub Action"},
		{string(entities.GroupImage), "container image digest"},
		{string(entities.GroupManifest), "tool pin"},
	}
}

// InGroup is one group's tasks, by label.
func InGroup(tasks []*entities.Task, group entities.Group) []*entities.Task {
	var rows []*entities.Task
	for _, task := range tasks {
		if task.Group == group {
			rows = append(rows, task)
		}
	}
	slices.SortStableFunc(
		rows,
		func(left, right *entities.Task) int { return strings.Compare(left.Label, right.Label) },
	)
	return rows
}

// SortedTasks is the tasks by group, then label.
func SortedTasks(tasks []*entities.Task) []*entities.Task {
	sorted := slices.Clone(tasks)
	slices.SortStableFunc(sorted, func(left, right *entities.Task) int {
		if order := strings.Compare(string(left.Group), string(right.Group)); order != 0 {
			return order
		}
		return strings.Compare(left.Label, right.Label)
	})
	return sorted
}

// SummaryPhrase is `8 GitHub Actions, 17 container image digests and 11 tool
// pins`.
func SummaryPhrase(applied []*entities.Task, fixes []entities.CopyChange) string {
	var words []string
	for _, noun := range groupNouns() {
		if rows := InGroup(applied, entities.Group(noun[0])); len(rows) > 0 {
			words = append(words, Plural(len(rows), noun[1]))
		}
	}
	if len(fixes) > 0 {
		words = append(words, copiesPhrase(len(fixes)))
	}
	if len(words) == 0 {
		return "nothing"
	}
	return Joined(words)
}

// fixedAdvisories are the advisories the applied updates fix, by task.
func fixedAdvisories(applied []*entities.Task) []*entities.Task {
	var fixing []*entities.Task
	for _, task := range applied {
		if len(task.Selection.Fixed) > 0 {
			fixing = append(fixing, task)
		}
	}
	return fixing
}

func countFixed(applied []*entities.Task) int {
	total := 0
	for _, task := range fixedAdvisories(applied) {
		total += len(task.Selection.Fixed)
	}
	return total
}
