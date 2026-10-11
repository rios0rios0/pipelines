package entities

import "slices"

// Group is the family of pin a task checks.
type Group string

// The three families of pin, in the order reports list them.
const (
	GroupManifest Group = "manifest"
	GroupAction   Group = "action"
	GroupImage    Group = "image"
)

// Upstream kinds a task can be resolved through.
const (
	KindGitHubRelease = "github-release"
	KindGitHubTag     = "github-tag"
	KindGitLabTag     = "gitlab-tag"
	KindPyPI          = "pypi"
	KindNpm           = "npm"
	KindRubyGems      = "rubygems"
	KindGoProxy       = "goproxy"
	// KindGoToolchain is a Go release line: the releases are the ones the
	// module proxy serves to GOTOOLCHAIN (`golang.org/toolchain`), and every
	// `go-version:`, `GoTool@0` input and `golang:` image is a copy of the pin
	// of its line.
	KindGoToolchain = "go-toolchain"
	KindImage       = "image"
)

// IsTaggedKind is a kind whose versions are git tags, and so can belong to more
// than one release line (see TagFamily).
func IsTaggedKind(kind string) bool {
	return kind == KindGitHubRelease || kind == KindGitHubTag || kind == KindGitLabTag
}

// SecurityStatus is what the advisory databases say about the pin in use today.
type SecurityStatus struct {
	// Packages are the pin's identities in the advisory database: one for most
	// pins, two for the Go toolchain (`stdlib` and `toolchain`).
	Packages []Package
	// Checked is false when there is no advisory source for the pin.
	Checked bool
	// Note says why the pin was not checked, or which version was.
	Note string
	// Version is the concrete version that was checked; for a range pin, the
	// newest release in the range, which is what installs today.
	Version string
	// Current are the advisories affecting it that nobody has accepted.
	Current []Advisory
	// Accepted are the advisories affecting it that an acceptance covers.
	Accepted []Advisory
}

// Queries are the advisory lookups for one version of the pin: one per package
// its advisories are filed under.
func (s SecurityStatus) Queries(version string) []AdvisoryQuery {
	queries := make([]AdvisoryQuery, 0, len(s.Packages))
	for _, pkg := range s.Packages {
		queries = append(queries, AdvisoryQuery{Package: pkg, Version: version})
	}
	return queries
}

// Answer is every advisory `found` holds for Queries(version), each once: an
// issue filed under two of the pin's packages is still one issue.
func (s SecurityStatus) Answer(found map[AdvisoryQuery][]Advisory, version string) []Advisory {
	var advisories []Advisory
	for _, query := range s.Queries(version) {
		for _, advisory := range found[query] {
			if !slices.ContainsFunc(advisories, func(seen Advisory) bool { return seen.ID == advisory.ID }) {
				advisories = append(advisories, advisory)
			}
		}
	}
	return advisories
}

// DigestPlan is one digest a bump rewrites, and where its new value came from.
type DigestPlan struct {
	Var    string
	Old    string
	New    string
	Source string
	URL    string
}

// VendoredPlan is a vendored file re-merged onto a new upstream release.
type VendoredPlan struct {
	Path       string
	Merged     string
	Enabled    []string
	Disabled   []string
	CompareURL string
}

// HistoryPlan is how the commit an action moves to relates to the one pinned.
type HistoryPlan struct {
	Status     string
	AheadBy    int
	Files      int
	CompareURL string
}

// ImagePlan is what scanning an image rebuild found, against the image pinned
// today.
type ImagePlan struct {
	Introduced []ImageFinding
	Fixed      []ImageFinding
	Known      int
	// Skipped is why the rebuild was not scanned, when it was not.
	Skipped string
}

// Plan is everything `--apply` needs from upstream for one update, resolved
// before any file is touched.
type Plan struct {
	New      string
	SHA      string
	Digests  []DigestPlan
	Vendored *VendoredPlan
	History  *HistoryPlan
	Image    *ImagePlan
}

// Task is one pinned dependency: what it is, what upstream says, what the
// policy chose, and what applying it did.
type Task struct {
	Group     Group
	Label     string
	Kind      string
	Coord     string
	Track     string
	Family    string
	HasFamily bool
	Current   string
	// CurrentSHA is, for an action, the commit pinned for Current.
	CurrentSHA string
	Entry      *ManifestEntry
	// Follows is, for a `golang:` image, the Go pin its tag names a release
	// of; Retag is the image name the pin moves it to, when it moves.
	Follows *ManifestEntry
	Retag   string

	Latest   string
	Outdated bool
	Error    string

	Security  SecurityStatus
	Selection Selection

	Apply     *Plan
	Refused   string
	Applied   bool
	Rewritten int
}

// Target is the version the policy proposes, or empty when it proposes none.
// A container image proposes the digest its tag resolves to now.
func (t *Task) Target() string {
	if t.Group == GroupImage {
		if t.Outdated {
			return t.Latest
		}
		return ""
	}
	if t.Selection.Target == nil {
		return ""
	}
	return t.Selection.Target.Version
}

// IsVulnerable is true when the pin in use today has unaccepted advisories.
func (t *Task) IsVulnerable() bool {
	return len(t.Security.Current) > 0
}

// Proposed is the target as the pin will spell it.
func (t *Task) Proposed() string {
	if t.Group == GroupManifest {
		return Restyle(t.Current, t.Target())
	}
	return t.Target()
}
