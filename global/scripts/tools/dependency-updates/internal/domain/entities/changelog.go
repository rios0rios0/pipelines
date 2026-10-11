package entities

import (
	"fmt"
	"regexp"
	"strings"
	"time"
)

// Changelog sections an update is recorded under.
const (
	ChangelogChanged  = "Changed"
	ChangelogSecurity = "Security"
)

// chlogTimeLayout is how `chlog new` stamps a fragment.
const chlogTimeLayout = "2006-01-02T15:04:05.000000000Z"

const nanosecondsPerSecond = int64(time.Second)

var unreleasedHeading = regexp.MustCompile(`(?i)^##\s*\[Unreleased\]`)

// FragmentName is a chlog fragment's path, named the way `chlog new` names
// them -- nanoseconds and four hex characters -- from a deterministic time and
// the fingerprint, so a rerun against an unchanged base writes the same file.
func FragmentName(when time.Time, fingerprint string, slot int) string {
	const suffixLength = 4
	offset := slot * suffixLength
	return fmt.Sprintf(".changes/unreleased/%d-%s.yaml",
		when.Unix()*nanosecondsPerSecond, fingerprint[offset:offset+suffixLength])
}

// FragmentContent is a chlog fragment's YAML. The body is single-quoted, so an
// apostrophe is doubled.
func FragmentContent(kind, body string, when time.Time) string {
	return fmt.Sprintf("kind: '%s'\nbody: '%s'\ntime: '%s'\n",
		kind, strings.ReplaceAll(body, "'", "''"), when.UTC().Format(chlogTimeLayout))
}

// InsertUnreleasedEntry adds `- body` under `## [Unreleased]` > `### section` of
// a Keep a Changelog file. It reports false when the file has no Unreleased
// section to add it to.
func InsertUnreleasedEntry(text, section, body string) (string, bool) {
	lines := strings.SplitAfter(text, "\n")
	if len(lines) > 0 && lines[len(lines)-1] == "" {
		lines = lines[:len(lines)-1]
	}
	newline := "\n"
	if strings.Count(text, "\r\n") > strings.Count(text, "\n")/2 {
		newline = "\r\n"
	}
	bullet := "- " + body + newline
	start := indexOf(lines, 0, len(lines), func(line string) bool { return unreleasedHeading.MatchString(line) })
	if start < 0 {
		return "", false
	}
	end := indexOf(lines, start+1, len(lines), func(line string) bool { return strings.HasPrefix(line, "## ") })
	if end < 0 {
		end = len(lines)
	}
	heading := "### " + strings.ToLower(section)
	existing := indexOf(lines, start+1, end, func(line string) bool {
		return strings.ToLower(strings.TrimSpace(line)) == heading
	})
	if existing < 0 {
		insert := skipBlank(lines, start+1, end)
		block := []string{newline, "### " + section + newline, newline, bullet}
		// A blank line before whatever follows -- the next subsection, or the
		// next release's heading -- whichever it turns out to be.
		if insert < len(lines) {
			block = append(block, newline)
		}
		return joinLines(lines[:start+1], block, lines[insert:]), true
	}
	insert := skipBlank(lines, existing+1, end)
	if insert < end && strings.HasPrefix(strings.TrimLeft(lines[insert], " \t"), "-") ||
		insert < end && strings.HasPrefix(strings.TrimLeft(lines[insert], " \t"), "*") {
		return joinLines(lines[:insert], []string{bullet}, lines[insert:]), true
	}
	block := []string{newline, bullet}
	if insert < len(lines) {
		block = append(block, newline)
	}
	return joinLines(lines[:existing+1], block, lines[insert:]), true
}

func indexOf(lines []string, from, to int, matches func(string) bool) int {
	for index := from; index < to; index++ {
		if matches(lines[index]) {
			return index
		}
	}
	return -1
}

func skipBlank(lines []string, from, to int) int {
	for from < to && strings.TrimSpace(lines[from]) == "" {
		from++
	}
	return from
}

func joinLines(parts ...[]string) string {
	var builder strings.Builder
	for _, part := range parts {
		for _, line := range part {
			builder.WriteString(line)
		}
	}
	return builder.String()
}
