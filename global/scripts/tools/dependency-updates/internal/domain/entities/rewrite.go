package entities

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"regexp"
	"slices"
	"strings"
)

// RefusedError is an update that is real but cannot be applied safely; it is
// left exactly as it is and handed to a person.
type RefusedError struct {
	Reason string
}

func (e *RefusedError) Error() string {
	return e.Reason
}

// Refuse builds a RefusedError from a format.
func Refuse(format string, arguments ...any) error {
	return &RefusedError{Reason: fmt.Sprintf(format, arguments...)}
}

// RepinAction re-pins every `uses:` of the action `coordinate`, sub-path actions
// included, to `sha` with its comment moved to `version`. It returns the new
// text and how many lines changed.
func RepinAction(text, coordinate, sha, version string) (string, int) {
	pattern := regexp.MustCompile(`(?m)(^[ \t]*(?:-[ \t]*)?uses:[ \t]*'` + regexp.QuoteMeta(coordinate) +
		`(?:/[^'@\s]*)?@)([0-9a-f]{40})('[ \t]*#[ \t]*)(\S+)`)
	var builder strings.Builder
	last, changes := 0, 0
	for _, match := range pattern.FindAllStringSubmatchIndex(text, -1) {
		if text[match[4]:match[5]] == sha && text[match[8]:match[9]] == version {
			continue
		}
		builder.WriteString(text[last:match[0]])
		builder.WriteString(text[match[2]:match[3]])
		builder.WriteString(sha)
		builder.WriteString(text[match[6]:match[7]])
		builder.WriteString(version)
		last = match[1]
		changes++
	}
	builder.WriteString(text[last:])
	return builder.String(), changes
}

// RepinImage rewrites every occurrence of the image reference `old` to
// `replacement`. Bounded on both sides, so `python:3.13-slim@sha256:...` is
// never rewritten inside a longer reference to a different repository that
// happens to end the same way -- a mirror of the same image, say.
func RepinImage(text, old, replacement string) (string, int) {
	var builder strings.Builder
	cursor, count := 0, 0
	for {
		index := strings.Index(text[cursor:], old)
		if index < 0 {
			break
		}
		start := cursor + index
		end := start + len(old)
		if !imageBounded(text, start, end) {
			builder.WriteString(text[cursor : start+1])
			cursor = start + 1
			continue
		}
		builder.WriteString(text[cursor:start])
		builder.WriteString(replacement)
		cursor = end
		count++
	}
	builder.WriteString(text[cursor:])
	return builder.String(), count
}

func imageBounded(text string, start, end int) bool {
	if start > 0 &&
		strings.ContainsRune(
			"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._/:-",
			rune(text[start-1]),
		) {
		return false
	}
	return end >= len(text) || !strings.ContainsRune("0123456789abcdef", rune(text[end]))
}

type manifestEdit struct {
	variable string
	pattern  string
	value    string
}

// RewriteManifest rewrites one pin and every digest of it in one edit, or
// nothing at all: each line it names must match exactly once.
func RewriteManifest(text string, entry ManifestEntry, proposed string, digests []DigestPlan) (string, error) {
	edits := make([]manifestEdit, 0, len(digests)+1)
	if entry.Style == PinStyleSpec {
		edits = append(edits, manifestEdit{
			variable: entry.Var,
			pattern: `(?m)^(` + regexp.QuoteMeta(entry.Var) + `="\$\{[A-Z0-9_]+:-)` +
				regexp.QuoteMeta(entry.SpecValue) + `(\}")(\r?)$`,
			value: entry.SpecValue[:len(entry.SpecValue)-len(entry.Current)] + proposed,
		})
	} else {
		edits = append(edits, manifestEdit{
			variable: entry.Var,
			pattern:  `(?m)^(` + regexp.QuoteMeta(entry.Var) + `=")` + regexp.QuoteMeta(entry.Current) + `(")(\r?)$`,
			value:    proposed,
		})
	}
	for _, digest := range digests {
		edits = append(edits, manifestEdit{
			variable: digest.Var,
			pattern:  `(?m)^(` + regexp.QuoteMeta(digest.Var) + `=")` + regexp.QuoteMeta(digest.Old) + `(")(\r?)$`,
			value:    digest.New,
		})
	}
	for _, edit := range edits {
		matches := regexp.MustCompile(edit.pattern).FindAllStringSubmatchIndex(text, -1)
		if len(matches) != 1 {
			return "", Refuse(
				"%s: expected exactly one `%s` line to rewrite, found %d",
				ManifestPath,
				edit.variable,
				len(matches),
			)
		}
		match := matches[0]
		text = text[:match[0]] + text[match[2]:match[3]] + edit.value + text[match[4]:match[5]] +
			text[match[6]:match[7]] + text[match[1]:]
	}
	return text, nil
}

// CopyChange is one inline copy brought in step with its manifest variable.
type CopyChange struct {
	Var  string
	File string
	From string
	To   string
	// Drifted is true when the copy already disagreed with the manifest before
	// this run, rather than being left behind by one of its bumps.
	Drifted bool
}

// AlignCopies sets every copy `inline` finds in `text` to `want`. `before` is
// the value the manifest held when the run started.
func AlignCopies(text string, inline InlineCopy, want, before, path string) (string, []CopyChange) {
	var (
		builder strings.Builder
		changes []CopyChange
	)
	last := 0
	for _, match := range inline.Pattern.FindAllStringSubmatchIndex(text, -1) {
		found := text[match[2]:match[3]]
		if SameValue(inline.Var, found, want) {
			continue
		}
		value := want
		if !IsDigestVar(inline.Var) {
			value = Restyle(found, want)
		}
		changes = append(changes, CopyChange{
			Var: inline.Var, File: path, From: found, To: value, Drifted: !SameValue(inline.Var, found, before),
		})
		builder.WriteString(text[last:match[2]])
		builder.WriteString(value)
		last = match[3]
	}
	builder.WriteString(text[last:])
	return builder.String(), changes
}

// Fingerprint is one hash for one SET of proposed changes.
//
// It is what lets a closed pull request mean "not this": the workflow does not
// propose a set it finds in a declined pull request, and any newer release
// changes the set -- and with it the hash. The proposed commit, every new digest
// and every re-merged file are part of it, so a re-pointed tag, a re-uploaded
// asset or a changed adjustment is proposed again rather than hidden behind an
// earlier "no".
func Fingerprint(applied []*Task, fixes []CopyChange) string {
	lines := make([]string, 0, len(applied)+len(fixes))
	for _, task := range applied {
		fields := []string{string(task.Group), task.Label, task.Apply.New, task.Apply.SHA}
		if task.Retag != "" {
			fields = append(fields, task.Retag)
		}
		for _, digest := range task.Apply.Digests {
			fields = append(fields, digest.New)
		}
		if task.Apply.Vendored != nil {
			fields = append(fields, SHA256Hex([]byte(task.Apply.Vendored.Merged)))
		}
		lines = append(lines, strings.Join(fields, "|"))
	}
	for _, fix := range fixes {
		lines = append(lines, strings.Join([]string{"inline", fix.File, fix.Var, fix.To}, "|"))
	}
	slices.Sort(lines)
	return SHA256Hex([]byte(strings.Join(lines, "\n")))
}

// SHA256Hex is the lower-case hex SHA-256 of `content`.
func SHA256Hex(content []byte) string {
	sum := sha256.Sum256(content)
	return hex.EncodeToString(sum[:])
}
