package entities

import (
	"fmt"
	"slices"
	"strconv"
	"strings"
)

// CVSS boundaries of the qualitative severities.
const (
	cvssCritical = 9.0
	cvssHigh     = 7.0
	cvssMedium   = 4.0
)

// ImageFinding is one known vulnerability of one package inside a container
// image. The IDs are one issue published under several identifiers
// (`CVE-2025-1`, `DEBIAN-CVE-2025-1`), as the scanner groups them.
type ImageFinding struct {
	Package   string
	Version   string
	Ecosystem string
	IDs       []string
	Severity  string
}

// SameIssue is true when two findings are one vulnerability of one package.
func (f ImageFinding) SameIssue(other ImageFinding) bool {
	return f.Package == other.Package &&
		slices.ContainsFunc(f.IDs, func(identifier string) bool { return slices.Contains(other.IDs, identifier) })
}

// Label is how a report names the finding: `openssl 3.0.15 CVE-2025-1 (HIGH)`.
func (f ImageFinding) Label() string {
	return fmt.Sprintf("%s %s %s (%s)", f.Package, f.Version, strings.Join(f.IDs, "/"), f.Severity)
}

// ImageScan is what scanning one image found.
type ImageScan struct {
	Reference string
	Findings  []ImageFinding
	// Skipped is why the image was not scanned -- it has no linux/amd64
	// manifest, say -- or empty when it was.
	Skipped string
}

// IntroducedFindings are the findings of `proposed` that `current` does not
// already have: what moving from one image to the other brings in.
func IntroducedFindings(current, proposed []ImageFinding) []ImageFinding {
	return slices.DeleteFunc(slices.Clone(proposed), func(finding ImageFinding) bool {
		return slices.ContainsFunc(current, finding.SameIssue)
	})
}

// SeverityFromCVSS names a CVSS base score the way advisories name severities.
func SeverityFromCVSS(score string) string {
	value, err := strconv.ParseFloat(strings.TrimSpace(score), 64)
	switch {
	case err != nil || value <= 0:
		return "UNRATED"
	case value >= cvssCritical:
		return "CRITICAL"
	case value >= cvssHigh:
		return "HIGH"
	case value >= cvssMedium:
		return "MEDIUM"
	default:
		return "LOW"
	}
}

// DescribeFindings is a short list for a report line, the rest counted.
func DescribeFindings(findings []ImageFinding, limit int) string {
	labels := make([]string, 0, min(len(findings), limit))
	for _, finding := range findings[:min(len(findings), limit)] {
		labels = append(labels, finding.Label())
	}
	described := strings.Join(labels, ", ")
	if len(findings) > limit {
		described += fmt.Sprintf(" and %d more", len(findings)-limit)
	}
	return described
}
