// Package entities holds the dependency-update domain: pins, versions, releases,
// advisories and the rules that decide which release a pin may move to.
//
// Nothing here performs I/O. Everything that reaches a network or a file goes
// through a port in the sibling `repositories` package, which is what lets the
// whole decision -- including the security policy -- be tested offline.
package entities

import (
	"regexp"
	"strconv"
	"strings"
)

var (
	// familyPattern finds the release line a tag belongs to: everything before
	// the first digit, minus an optional `v`. ASCII, because RE2's `\d` is
	// `[0-9]`: a version is never spelt in another script's digits.
	familyPattern = regexp.MustCompile(`^(\D*?)v?\d`)
	// majorOnlyPattern is a pin naming a major alone (`wrangler@4`).
	majorOnlyPattern = regexp.MustCompile(`^\d+$`)
	// chunkSeparators split a version into the components that are compared.
	chunkSeparators = regexp.MustCompile(`[.\-_+]`)
)

// versionPrefixes are the spellings upstreams put in front of the same release.
// `v0.11.0` and `0.11.0`, `codeql-bundle-v2.26.3` and `2.26.3`: normalising both
// sides before comparing is what keeps the checker from reporting an "update"
// from a version to itself. The longest prefix comes first.
func versionPrefixes() []string {
	return []string{"codeql-bundle-v", "codeql-bundle-", "v"}
}

// Normalise strips the spelling an upstream wraps around a version.
func Normalise(version string) string {
	version = strings.TrimSpace(version)
	for _, prefix := range versionPrefixes() {
		if after, found := strings.CutPrefix(version, prefix); found {
			return after
		}
	}
	return version
}

// Parts are the leading numeric components of a version, for ordering.
//
// They stop at the first component that is not a number, so Go
// pseudo-versions (`v0.0.0-20160331181800-b5bfa59ec0ad`) and the SonarScanner
// image's `12.1.0.3233_8.0.1` both order by what they share with a release, and
// for anything beyond that "different" is the only judgement worth making.
func Parts(version string) []int64 {
	chunks := chunkSeparators.Split(Normalise(version), -1)
	numeric := make([]int64, 0, len(chunks))
	for _, chunk := range chunks {
		if !isDigits(chunk) {
			break
		}
		value, err := strconv.ParseInt(chunk, 10, 64)
		if err != nil {
			break
		}
		numeric = append(numeric, value)
	}
	return numeric
}

func isDigits(text string) bool {
	if text == "" {
		return false
	}
	for _, character := range text {
		if character < '0' || character > '9' {
			return false
		}
	}
	return true
}

// compareParts orders two component lists the way tuples order: element by
// element, and a list that is a prefix of the other is the smaller one.
func compareParts(left, right []int64) int {
	for index := 0; index < len(left) && index < len(right); index++ {
		switch {
		case left[index] < right[index]:
			return -1
		case left[index] > right[index]:
			return 1
		}
	}
	switch {
	case len(left) < len(right):
		return -1
	case len(left) > len(right):
		return 1
	default:
		return 0
	}
}

// IsNewer is true when `latest` is a release beyond `pinned`.
//
// It compares only as many components as the PIN declares, which is what makes
// a major-only pin work: `wrangler@4` against `4.123.0` is current, against
// `5.0.0` is not. A pin of `4.1` is judged on major and minor, a full `1.2.3`
// on all three.
func IsNewer(pinned, latest string) bool {
	pinnedParts, latestParts := Parts(pinned), Parts(latest)
	if len(pinnedParts) == 0 || len(latestParts) == 0 {
		return Normalise(pinned) != Normalise(latest)
	}
	width := min(len(pinnedParts), len(latestParts))
	return compareParts(latestParts[:width], pinnedParts[:width]) > 0
}

// CompareVersions orders two versions by their numeric components, treating a
// missing trailing component as zero, so `41` and `41.0.0` are the same release.
// That is the ordering an advisory's `introduced`/`fixed` events are written in.
func CompareVersions(left, right string) int {
	leftParts, rightParts := Parts(left), Parts(right)
	width := max(len(leftParts), len(rightParts))
	return compareParts(padded(leftParts, width), padded(rightParts, width))
}

func padded(parts []int64, width int) []int64 {
	if len(parts) >= width {
		return parts
	}
	return append(append(make([]int64, 0, width), parts...), make([]int64, width-len(parts))...)
}

// TagFamily is the release line a tag belongs to: `codeql-bundle` for
// `codeql-bundle-v2.27.2`, empty for `v4.38.3`, and not found for a tag with no
// digit at all.
//
// One repository can publish two unrelated release lines. `github/codeql-action`
// tags the action `v4.x` and the CodeQL bundle `codeql-bundle-v2.x`, and marks
// whichever shipped last as its latest release -- so asking for "the latest
// release" answered the action pin with a bundle version, which compares as
// OLDER, and the action read as current at v4.37.7 while v4.38.3 was out.
// Comparing only within one family is what keeps the two lines apart.
//
// `v4.38.3` and `4.38.3` are the same family: a leading `v` is spelling, not a
// release line.
func TagFamily(tag string) (string, bool) {
	match := familyPattern.FindStringSubmatch(tag)
	if match == nil {
		return "", false
	}
	return strings.TrimRight(match[1], "-_."), true
}

// IsMajorOnly is a pin naming a major alone (`wrangler@4`): a deliberate range,
// not an exact build.
func IsMajorOnly(version string) bool {
	return majorOnlyPattern.MatchString(Normalise(version))
}

// Restyle writes `latest` the way the pin already writes `current`.
//
// Upstream tags carry prefixes the pins do not (`v8.31.0` for a pin written
// `8.30.1`) and the reverse (`codeql-bundle-v2.27.2` IS the pin), and a
// major-only pin (`wrangler@4`) is a deliberate range rather than an exact
// build. Each pin keeps its own shape: the prefix it already has, and its width
// when it names a major alone.
func Restyle(current, latest string) string {
	prefix := current[:len(current)-len(Normalise(current))]
	value := Normalise(latest)
	if IsMajorOnly(current) {
		if latestParts := Parts(latest); len(latestParts) > 0 {
			value = strconv.FormatInt(latestParts[0], 10)
		}
	}
	return prefix + value
}

// InLine is true when `version` belongs to the release line `line` names: a
// major (`1`, or `v1`) or a minor line (`1.27`). It is how a pin held with
// `track=` judges a release -- GoReleaser to 1.x, the Go toolchain to 1.27.x.
func InLine(version, line string) bool {
	prefix, parts := Parts(line), Parts(version)
	return len(prefix) > 0 && len(parts) >= len(prefix) && compareParts(parts[:len(prefix)], prefix) == 0
}

// LineName is a release line as a sentence names it: `major 1`, `the 1.27 line`.
func LineName(line string) string {
	if len(Parts(line)) > 1 {
		return "the " + Normalise(line) + " line"
	}
	return "major " + Normalise(line)
}

// IsMajor is true when moving from `current` to `proposed` changes the major.
func IsMajor(current, proposed string) bool {
	currentParts, proposedParts := Parts(current), Parts(proposed)
	return len(currentParts) > 0 && len(proposedParts) > 0 && currentParts[0] != proposedParts[0]
}

var (
	// semverPrerelease is a numeric core followed by semver's pre-release
	// hyphen: `2.0.0-rc.1`, `1.0.0-beta`.
	semverPrerelease = regexp.MustCompile(`^\d+(\.\d+)*-`)
	// pep440Prerelease is a numeric core followed by one of PEP 440's
	// pre-release or development segments: `1.2.0rc1`, `2.30.0a1`, `3.0.0.dev2`.
	pep440Prerelease = regexp.MustCompile(`(?i)^\d+(\.\d+)*[._-]?(a|alpha|b|beta|c|rc|pre|preview|dev)[._-]?\d*$`)
	// pseudoVersionPattern is a Go pseudo-version's tail: a UTC timestamp and a
	// twelve-character commit prefix.
	pseudoVersionPattern = regexp.MustCompile(`-\d{14}-[0-9a-f]{12}$`)
)

// IsPrerelease recognises the release spellings no pin is ever moved to:
// semver's pre-release hyphen and PEP 440's pre-release and development
// segments. A registry's own pre-release flag is honoured as well; this catches
// the release whose maintainer forgot to set it.
//
// Deliberately NOT "anything that is not numbers and dots". A release named
// something hostile (`1.3.0";touch_pwned;"`) must reach the refusal that names
// it to a person, not vanish from the candidates as a pre-release nobody sees.
// A Go pseudo-version is the module proxy's canonical name for a commit, not a
// pre-release.
func IsPrerelease(version string) bool {
	normalised := Normalise(version)
	if pseudoVersionPattern.MatchString(normalised) {
		return false
	}
	return semverPrerelease.MatchString(normalised) || pep440Prerelease.MatchString(normalised)
}
