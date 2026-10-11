package entities

import (
	"regexp"
	"slices"
	"strings"
	"time"
)

// Settings is a repository's `.dependency-updates.json`: decisions about its
// own pins, each written down where review sees it.
type Settings struct {
	// Ignore are labels never tracked: a genuinely ROLLING reference such as
	// `alpine:edge`, or a dependency somebody decided to stay on for good.
	Ignore []string
	// Cooldown overrides DefaultCooldown when HasCooldown.
	Cooldown    time.Duration
	HasCooldown bool
	// CooldownExempt are labels proposed as soon as they are released.
	CooldownExempt []string
	// Acceptances are known advisories a person decided to live with, each
	// until a date and with a reason.
	Acceptances []Acceptance
}

// Untracked is a pin, or a digest of one, that cannot be checked because an
// annotation is missing. It fails the run rather than being skipped quietly,
// or coverage shrinks one forgotten annotation at a time while the job stays
// green.
type Untracked struct {
	Name    string
	Current string
	// Missing is the annotation that is absent: `upstream`, `asset` or `osv`.
	Missing string
}

// AdvisoryQuery asks an advisory database about one version of one package.
type AdvisoryQuery struct {
	Package Package
	Version string
}

// Comparison relates two commits of one repository, the way GitHub's compare
// view does: `ahead` when the head descends from the base.
type Comparison struct {
	Status  string
	AheadBy int
	Files   int
}

// Comparison statuses that mean the head descends from (or is) the base.
const (
	ComparisonAhead     = "ahead"
	ComparisonIdentical = "identical"
)

// Descends is true when the head is the base or one of its descendants.
func (c Comparison) Descends() bool {
	return c.Status == ComparisonAhead || c.Status == ComparisonIdentical
}

// The fingerprint travels in two places the guard can read back: a trailer in
// the workflow's own commits, and an HTML comment in the pull request body.
const (
	FingerprintTrailer = "Dependency-Updates-Fingerprint:"
	FingerprintMarker  = "dependency-updates-fingerprint:"
)

// MarkerComment is the pull request body's fingerprint comment.
func MarkerComment(fingerprint string) string {
	return "<!-- " + FingerprintMarker + " " + fingerprint + " -->"
}

// PullRequest is one pull request opened from the update branch.
type PullRequest struct {
	Number int
	Merged bool
	Body   string
}

// Commit is one commit on the update branch.
type Commit struct {
	SHA     string
	Parents int
	Message string
}

// MatchesAny is true when `label` matches one of the shell-style patterns, with
// fnmatch semantics: `*` crosses a `/`, unlike Go's [path.Match], so
// `rios0rios0/*` and `*checkout` mean what a reader of the settings file
// expects.
func MatchesAny(label string, patterns []string) bool {
	return slices.ContainsFunc(patterns, func(pattern string) bool {
		return globPattern(pattern).MatchString(label)
	})
}

func globPattern(pattern string) *regexp.Regexp {
	var builder strings.Builder
	builder.WriteString("^")
	for index := 0; index < len(pattern); index++ {
		switch character := pattern[index]; character {
		case '*':
			builder.WriteString(".*")
		case '?':
			builder.WriteString(".")
		case '[':
			closing := strings.IndexByte(pattern[index+1:], ']')
			if closing < 0 {
				builder.WriteString(`\[`)
				continue
			}
			class := pattern[index+1 : index+1+closing]
			if strings.HasPrefix(class, "!") {
				class = "^" + class[1:]
			}
			builder.WriteString("[" + strings.ReplaceAll(class, `\`, `\\`) + "]")
			index += closing + 1
		default:
			builder.WriteString(regexp.QuoteMeta(string(character)))
		}
	}
	builder.WriteString("$")
	compiled, err := regexp.Compile(builder.String())
	if err != nil {
		return regexp.MustCompile("^" + regexp.QuoteMeta(pattern) + "$")
	}
	return compiled
}
