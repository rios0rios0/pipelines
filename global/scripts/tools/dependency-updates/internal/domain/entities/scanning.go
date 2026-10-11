package entities

import (
	"regexp"
	"strings"
)

var (
	usesPattern  = regexp.MustCompile(`^\s*(?:-\s*)?uses:\s*'([^'@]+)@([0-9a-f]{40})'\s*#\s*(\S+)`)
	imagePattern = regexp.MustCompile(`^\s*(?:-\s*)?image:\s*'([^']+@sha256:[0-9a-f]+)'`)
	fromPattern  = regexp.MustCompile(`^FROM\s+(\S+@sha256:[0-9a-f]+)`)
)

// ownerRepositorySegments are the `owner/repo` part of an action path.
const ownerRepositorySegments = 2

// firstPartyOwner is this library's own GitHub owner: its actions are pinned to
// `@main` or a self-reference by design, and are never checked here.
const firstPartyOwner = "rios0rios0/"

// ActionPin is the newest version a repository pins an action at, and the
// commit pinned for it.
type ActionPin struct {
	Version string
	SHA     string
}

// ScanActions records the third-party actions `text` pins in `found`.
//
// Sub-path actions (`github/codeql-action/init`) collapse onto their owning
// repository, which is what carries the release. When one action is pinned at
// several versions, the newest is the one an update moves from.
func ScanActions(text string, found map[string]ActionPin) {
	for line := range strings.Lines(text) {
		match := usesPattern.FindStringSubmatch(strings.TrimRight(line, "\r\n"))
		if match == nil || strings.HasPrefix(match[1], firstPartyOwner) {
			continue
		}
		ownerRepository := strings.Join(firstSegments(match[1], ownerRepositorySegments), "/")
		version := match[3]
		if existing, seen := found[ownerRepository]; !seen || IsNewer(existing.Version, version) {
			found[ownerRepository] = ActionPin{Version: version, SHA: match[2]}
		}
	}
}

// ActionOccurrence is one `uses:` line: the action's repository, the commit it
// pins and the version its comment names.
type ActionOccurrence struct {
	Repository string
	SHA        string
	Version    string
}

// ScanActionOccurrences lists every third-party `uses:` pin in `text`.
func ScanActionOccurrences(text string) []ActionOccurrence {
	var found []ActionOccurrence
	for line := range strings.Lines(text) {
		match := usesPattern.FindStringSubmatch(strings.TrimRight(line, "\r\n"))
		if match == nil || strings.HasPrefix(match[1], firstPartyOwner) {
			continue
		}
		found = append(found, ActionOccurrence{
			Repository: strings.Join(
				firstSegments(match[1], ownerRepositorySegments),
				"/",
			),
			SHA:     match[2],
			Version: match[3],
		})
	}
	return found
}

func firstSegments(path string, count int) []string {
	segments := strings.Split(path, "/")
	return segments[:min(count, len(segments))]
}

// ScanImages records every digest-pinned image reference in `text` in `found`,
// mapped to its digest. A Dockerfile is read for `FROM`, anything else for
// `image:`.
func ScanImages(text string, dockerfile bool, found map[string]string) {
	pattern := imagePattern
	if dockerfile {
		pattern = fromPattern
	}
	for line := range strings.Lines(text) {
		if match := pattern.FindStringSubmatch(strings.TrimRight(line, "\r\n")); match != nil {
			_, digest, _ := strings.Cut(match[1], "@")
			found[match[1]] = digest
		}
	}
}

// InlineCopy is a manifest value written a second time in a template that has
// no `SCRIPTS_DIR` to source the manifest from. The pattern's one group is the
// copy.
type InlineCopy struct {
	Var     string
	Pattern *regexp.Regexp
}

// InlineCopies is every copy the checker keeps in step with the manifest.
//
// A copy is not a problem; a copy that has drifted is, and it drifts silently:
// the Azure DevOps ProGuard job was still on 7.6.1 and the Azure Terragrunt
// abstract on 1.1.3, a bump after the manifest had moved on, and nothing
// reported it. The same table drives drift detection and `--apply`, so a copy
// the check knows about is a copy the bump rewrites.
func InlineCopies() []InlineCopy {
	rows := [][2]string{
		{"PDM_SPEC", `pip install[^"\n]*"pdm==([0-9][^"]*)"`},
		{"VULTURE_SPEC", `pip install[^"\n]*"vulture==([0-9][^"]*)"`},
		{"KNIP_SPEC", `npx --yes[^\n]*knip@([0-9][^\s'"]*)`},
		{"GOVULNCHECK_PINNED_VERSION", `go install golang\.org/x/vuln/cmd/govulncheck@v?([0-9][^\s'"]*)`},
		{"BUNDLER_AUDIT_SPEC", `gem install bundler-audit -v ([0-9][^\s'"]*)`},
		{"GORELEASER_PINNED_VERSION", `GORELEASER_VERSION:\s*"([0-9][^"]*)"`},
		{"PROGUARD_PINNED_VERSION", `Guardsquare/proguard/releases/download/v([0-9][^/"'\s]*)/`},
		// The suffix is consumed rather than looked ahead at: RE2 has no
		// lookaround, and only the group is ever rewritten.
		{"PROGUARD_PINNED_VERSION", `proguard-([0-9][0-9.]*[0-9])(?:\.tar\.gz|/lib/)`},
		{"PROGUARD_SHA256", `"([0-9a-f]{64})  /tmp/proguard\.tar\.gz"`},
		{"TERRAGRUNT_PINNED_VERSION", `TERRAGRUNT_VERSION="([0-9][^"]*)"`},
		{"TERRAGRUNT_SHA256_AMD64", `TERRAGRUNT_SHA256="([0-9a-f]{64})"`},
		{"STOML_PINNED_VERSION", `STOML_VERSION="([0-9][^"]*)"`},
		{"STOML_SHA256_AMD64", `STOML_SHA256="([0-9a-f]{64})"`},
	}
	copies := make([]InlineCopy, 0, len(rows))
	for _, row := range rows {
		copies = append(copies, InlineCopy{Var: row[0], Pattern: regexp.MustCompile(row[1])})
	}
	return copies
}

// IsDigestVar is a manifest variable holding a SHA-256.
func IsDigestVar(variable string) bool {
	return strings.Contains(variable, "_SHA256")
}

// SameValue compares a copy with the value it mirrors: digests case-blind,
// versions by their normalised spelling.
func SameValue(variable, found, want string) bool {
	if IsDigestVar(variable) {
		return strings.EqualFold(found, want)
	}
	return Normalise(found) == Normalise(want)
}

// Drift is one inline copy that disagrees with the manifest.
type Drift struct {
	Name     string
	File     string
	Inline   string
	Manifest string
}

// SourceText is one scanned file: its repository path and its contents.
type SourceText struct {
	Path string
	Text string
}

// FindDrift lists every copy in `files` that disagrees with `expected`, copy by
// copy and then file by file.
func FindDrift(files []SourceText, expected map[string]string) []Drift {
	var drifts []Drift
	for _, inline := range InlineCopies() {
		want, tracked := expected[inline.Var]
		if !tracked {
			continue
		}
		for _, file := range files {
			for _, match := range inline.Pattern.FindAllStringSubmatch(file.Text, -1) {
				if !SameValue(inline.Var, match[1], want) {
					drifts = append(drifts, Drift{Name: inline.Var, File: file.Path, Inline: match[1], Manifest: want})
				}
			}
		}
	}
	return drifts
}
