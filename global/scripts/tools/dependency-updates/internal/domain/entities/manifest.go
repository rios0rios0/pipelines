package entities

import (
	"regexp"
	"strconv"
	"strings"
)

// ManifestPath is where the manifest lives, relative to the repository root. It
// is absent in a CONSUMER's repository, which has no pinned-versions.sh of its
// own; the action and image scans are generic, so the check still does
// something useful there.
const ManifestPath = "global/scripts/shared/pinned-versions.sh"

// Kinds a manifest entry can have besides an upstream kind.
const (
	// KindUnannotated is a pin with no `# upstream:` annotation: reported as
	// untracked rather than skipped, or coverage shrinks one forgotten
	// annotation at a time while the job stays green.
	KindUnannotated = "unannotated"
	// KindNone is a pin deliberately not tracked upstream.
	KindNone = "none"
)

// PinStyle is how a manifest line spells its value.
type PinStyle string

// The two shapes a pinned value is written in.
const (
	// PinStyleVersion is `NAME_PINNED_VERSION="1.2.3"`.
	PinStyleVersion PinStyle = "pin"
	// PinStyleSpec is `NAME_SPEC="${NAME_SPEC:-pkg==1.2.3}"`.
	PinStyleSpec PinStyle = "spec"
)

// Digest is one committed SHA-256 and the `# asset:` template that names the
// file it is of. A digest belongs to the pin whose name it extends
// (`GITLEAKS_SHA256_X64` to `GITLEAKS`).
type Digest struct {
	Var   string
	Value string
	Asset string
}

// AdvisorySource is where a pin's known vulnerabilities are looked up, from a
// `# osv: <ecosystem> <package>` annotation. `# osv: none` records, in review,
// that no advisory database covers the artifact -- a tool with no package
// identity, a configuration file -- so its absence is a decision rather than a
// gap that reads as "no known vulnerabilities".
type AdvisorySource struct {
	Ecosystem string
	Package   string
	None      bool
}

// ManifestEntry is one pin of `pinned-versions.sh` with the annotations that say
// how to check it, how to rewrite it, and where its advisories come from.
type ManifestEntry struct {
	Kind       string
	Name       string
	Var        string
	Style      PinStyle
	SpecValue  string
	Current    string
	Coord      string
	TrackMajor string
	// Ceiling names another pin this one may never move past: the golden
	// golangci-lint configuration must not name a linter the pinned binary
	// does not have.
	Ceiling string
	// CooldownDays overrides the default minimum release age when HasCooldown.
	CooldownDays int
	HasCooldown  bool
	Checksums    string
	Advisories   *AdvisorySource
	// Vendored is the repository path of a file copied from upstream and
	// adjusted here; bumping the pin re-applies those adjustments to the new
	// upstream release with a three-way merge.
	Vendored string
	Digests  []Digest
}

// Line shapes of `pinned-versions.sh`, each matched against one line.
var (
	upstreamAnnotation  = regexp.MustCompile(`^#\s*upstream:\s*([a-z-]+)\s+(\S+)(.*)$`)
	checksumsAnnotation = regexp.MustCompile(`^#\s*checksums:\s*(\S+)\s*$`)
	assetAnnotation     = regexp.MustCompile(`^#\s*asset:\s*(\S+)\s*$`)
	osvAnnotation       = regexp.MustCompile(`^#\s*osv:\s*(\S+)(?:\s+(\S+))?\s*$`)
	vendoredAnnotation  = regexp.MustCompile(`^#\s*vendored:\s*(\S+)\s*$`)
	pinLine             = regexp.MustCompile(`^([A-Z0-9_]+)_PINNED_VERSION="([^"]*)"`)
	specLine            = regexp.MustCompile(`^([A-Z0-9_]+)_SPEC="\$\{[A-Z0-9_]+:-([^}"]*)\}"`)
	// digestLine matches any `NAME="<64 hex>"`; that the name carries `_SHA256`
	// is checked in code, so the name's two runs of one character class never
	// have to be split by the engine.
	digestLine = regexp.MustCompile(`^([A-Z0-9_]+)="([0-9a-f]{64})"\s*$`)
)

// SpecVersion pulls the version out of a package spec (`pdm==2.28.1`,
// `knip@6.32.2`, `bundler-audit:0.9.3`).
func SpecVersion(value string) string {
	for _, separator := range []string{"==", "@", ":"} {
		if index := strings.LastIndex(value, separator); index >= 0 {
			return value[index+len(separator):]
		}
	}
	return value
}

// ParseManifest reads every pin of `pinned-versions.sh` with its annotations.
//
// The annotations are comments directly above what they describe:
//
//	# upstream:  <kind> <coordinate> [track=<major>] [ceiling=<PIN>] [cooldown=<days>]
//	# checksums: <url with {version}>       the publisher's checksum manifest
//	# osv:       <ecosystem> <package>|none  where advisories are looked up
//	# vendored:  <repository path>           a file copied from the release
//	# asset:     <url with {version}>       above a digest -- the file it is of
//
// The pin annotations may come in any order: a `# checksums:` line dropped for
// sitting above `# upstream:` would take its cross-check with it, silently.
func ParseManifest(text string) []ManifestEntry {
	parser := &manifestParser{}
	for raw := range strings.SplitSeq(text, "\n") {
		parser.feed(strings.TrimSuffix(raw, "\r"))
	}
	return parser.entries
}

type pendingUpstream struct {
	kind, coord, trackMajor, ceiling string
	cooldownDays                     int
	hasCooldown                      bool
}

type manifestParser struct {
	entries    []ManifestEntry
	upstream   *pendingUpstream
	checksums  string
	advisories *AdvisorySource
	vendored   string
	asset      string
}

func (p *manifestParser) feed(raw string) {
	stripped := strings.TrimSpace(raw)
	if p.annotation(stripped) {
		return
	}
	if digest := digestLine.FindStringSubmatch(raw); digest != nil && strings.Contains(digest[1], "_SHA256") {
		p.addDigest(digest[1], digest[2])
		return
	}
	if pin := pinLine.FindStringSubmatch(raw); pin != nil {
		p.addPin(pin[1], pin[2], PinStyleVersion)
		return
	}
	if spec := specLine.FindStringSubmatch(raw); spec != nil {
		p.addPin(spec[1], spec[2], PinStyleSpec)
		return
	}
	if stripped != "" && !strings.HasPrefix(stripped, "#") {
		// Any other code line ends whatever was waiting: an annotation
		// describes the line directly beneath its comment block, never one
		// further down.
		p.resetPin()
		p.asset = ""
	}
}

func (p *manifestParser) annotation(stripped string) bool {
	if match := upstreamAnnotation.FindStringSubmatch(stripped); match != nil {
		p.upstream = parseUpstreamOptions(match[1], match[2], match[3])
		return true
	}
	if match := checksumsAnnotation.FindStringSubmatch(stripped); match != nil {
		p.checksums = match[1]
		return true
	}
	if match := osvAnnotation.FindStringSubmatch(stripped); match != nil {
		p.advisories = &AdvisorySource{Ecosystem: match[1], Package: match[2], None: match[1] == KindNone}
		return true
	}
	if match := vendoredAnnotation.FindStringSubmatch(stripped); match != nil {
		p.vendored = match[1]
		return true
	}
	if match := assetAnnotation.FindStringSubmatch(stripped); match != nil {
		p.asset = match[1]
		return true
	}
	return false
}

func parseUpstreamOptions(kind, coord, options string) *pendingUpstream {
	upstream := &pendingUpstream{kind: kind, coord: coord}
	for word := range strings.FieldsSeq(options) {
		key, value, found := strings.Cut(word, "=")
		if !found || value == "" {
			continue
		}
		switch key {
		case "track":
			upstream.trackMajor = value
		case "ceiling":
			upstream.ceiling = value
		case "cooldown":
			if days, err := strconv.Atoi(value); err == nil && days >= 0 {
				upstream.cooldownDays, upstream.hasCooldown = days, true
			}
		}
	}
	return upstream
}

func (p *manifestParser) addDigest(variable, value string) {
	owner := -1
	for index := range p.entries {
		name := p.entries[index].Name
		if strings.HasPrefix(variable, name+"_SHA256") && (owner < 0 || len(name) > len(p.entries[owner].Name)) {
			owner = index
		}
	}
	if owner >= 0 {
		p.entries[owner].Digests = append(p.entries[owner].Digests, Digest{Var: variable, Value: value, Asset: p.asset})
	}
	p.asset = ""
}

func (p *manifestParser) addPin(name, value string, style PinStyle) {
	entry := ManifestEntry{Kind: KindUnannotated, Name: name, Style: style, Current: value}
	if style == PinStyleSpec {
		entry.Var = name + "_SPEC"
		entry.SpecValue = value
		entry.Current = SpecVersion(value)
	} else {
		entry.Var = name + "_PINNED_VERSION"
	}
	if p.upstream != nil {
		entry.Kind = p.upstream.kind
		entry.Coord = p.upstream.coord
		entry.TrackMajor = p.upstream.trackMajor
		entry.Ceiling = p.upstream.ceiling
		entry.CooldownDays, entry.HasCooldown = p.upstream.cooldownDays, p.upstream.hasCooldown
		entry.Checksums = p.checksums
		entry.Advisories = p.advisories
		entry.Vendored = p.vendored
	}
	p.entries = append(p.entries, entry)
	p.resetPin()
}

func (p *manifestParser) resetPin() {
	p.upstream = nil
	p.checksums = ""
	p.advisories = nil
	p.vendored = ""
}

// ManifestValues maps every manifest variable an inline copy can mirror to its
// value: each pin's version and each of its digests.
func ManifestValues(manifest []ManifestEntry) map[string]string {
	values := make(map[string]string, len(manifest))
	for _, entry := range manifest {
		values[entry.Var] = entry.Current
		for _, digest := range entry.Digests {
			values[digest.Var] = digest.Value
		}
	}
	return values
}

// FindEntry is the manifest entry named `name`, or nil.
func FindEntry(manifest []ManifestEntry, name string) *ManifestEntry {
	for index := range manifest {
		if manifest[index].Name == name {
			return &manifest[index]
		}
	}
	return nil
}
