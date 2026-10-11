package entities

import (
	"regexp"
	"strings"
)

var (
	// SafeVersion is what an upstream may call a release before it is written
	// into a SOURCED shell file, a YAML comment and a Markdown table.
	// Deliberately narrow: no quote, `$`, backtick, space, `|`, `<` or newline
	// can reach any of the three, so a hostile or merely odd name is refused
	// instead of executed or rendered.
	SafeVersion = regexp.MustCompile(`^[0-9A-Za-z][0-9A-Za-z._+-]{0,127}$`)
	// SafeTag is the same for an action tag, which may carry a `/`.
	SafeTag = regexp.MustCompile(`^[0-9A-Za-z][0-9A-Za-z._+/-]{0,127}$`)
	// ImageDigest is an OCI content digest.
	ImageDigest = regexp.MustCompile(`^sha256:[0-9a-f]{64}$`)
	// CommitSHA is a full git commit SHA.
	CommitSHA = regexp.MustCompile(`^[0-9a-f]{40}$`)
	// SHA256Value is a lower-case hex SHA-256.
	SHA256Value = regexp.MustCompile(`^[0-9a-f]{64}$`)

	// gnuSum is `<hex>  <name>` or `<hex> *<name>`, matched against a STRIPPED
	// line so the name runs to the end with no trailing whitespace to give back.
	gnuSum = regexp.MustCompile(`^([0-9a-fA-F]{64})\s+\*?([^\s*]\S*)$`)
	// bsdSum is `SHA256 (<name>) = <hex>`. The algorithm is matched whole, so a
	// `SHA3-256` line of yq's thirty-algorithm `checksums-bsd` is never read as
	// SHA-256.
	bsdSum = regexp.MustCompile(`^SHA-?256\s*\(([^)]+)\)\s*=\s*([0-9a-fA-F]{64})\s*$`)
)

// Render fills an `# asset:` or `# checksums:` template's `{version}`.
func Render(template, version string) string {
	return strings.ReplaceAll(template, "{version}", version)
}

// AssetName is the file name at the end of a URL.
func AssetName(url string) string {
	return url[strings.LastIndex(url, "/")+1:]
}

// PublishedChecksum is the SHA-256 a checksum manifest publishes for `asset`,
// from either common format, or empty when it publishes none. A file holding
// one bare digest is a per-asset checksum and answers for that asset.
func PublishedChecksum(text, asset string) string {
	for line := range strings.Lines(text) {
		stripped := strings.TrimSpace(line)
		if match := gnuSum.FindStringSubmatch(stripped); match != nil && AssetName(match[2]) == asset {
			return strings.ToLower(match[1])
		}
		if match := bsdSum.FindStringSubmatch(stripped); match != nil && AssetName(match[1]) == asset {
			return strings.ToLower(match[2])
		}
	}
	if bare := strings.ToLower(strings.TrimSpace(text)); SHA256Value.MatchString(bare) {
		return bare
	}
	return ""
}
