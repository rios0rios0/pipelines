package entities

import (
	"fmt"
	"maps"
	"regexp"
	"slices"
	"strings"
)

// goImage is the image repository whose tags name Go releases.
const goImage = "golang"

// goImageTag splits a `golang` tag into the release it names and the variant
// after it: `1.27.1-bookworm`, `1.27.1-alpine3.24`, `1.27.1`. A tag naming no
// single release (`1.27`, `bookworm`, `latest`) is a rolling tag, not a copy of
// a pin: it moves on its own, and the digest check already watches it.
var goImageTag = regexp.MustCompile(`^(\d+\.\d+\.\d+)((?:-[a-z0-9.]+)*)$`)

// goReleaseCopies find a Go release written outside the manifest; the group is
// the release. `actions/setup-go`'s `go-version:` -- never `go-version-file:`,
// which reads a consumer's own go.mod -- and the `version:` input of an Azure
// DevOps `GoTool@0` task, looked for within the task's own lines.
func goReleaseCopies() []*regexp.Regexp {
	return []*regexp.Regexp{
		regexp.MustCompile(`go-version:[ \t]*'(\d+\.\d+(?:\.\d+)?)'`),
		regexp.MustCompile(`GoTool@0'?[ \t]*\r?\n(?:[ \t]+[^\n]*\n){0,8}?[ \t]+version:[ \t]*'(\d+\.\d+(?:\.\d+)?)'`),
	}
}

// GoImage is a `golang:<release>[-<variant>]` image name split apart.
type GoImage struct {
	Release string
	Variant string
}

// ParseGoImage reads an image reference -- its digest, if any, aside -- as a Go
// image naming one release.
func ParseGoImage(reference string) (GoImage, bool) {
	name, _, _ := strings.Cut(reference, "@")
	repository, tag, found := strings.Cut(name, ":")
	if !found || repository != goImage {
		return GoImage{}, false
	}
	match := goImageTag.FindStringSubmatch(tag)
	if match == nil {
		return GoImage{}, false
	}
	return GoImage{Release: match[1], Variant: match[2]}, true
}

// Line is the image's Go release line: `1.27` for `golang:1.27.2-bookworm`.
func (g GoImage) Line() string {
	return goLine(g.Release)
}

// Name is this variant's image name for `release`: the tag a moved pin gives
// the image.
func (g GoImage) Name(release string) string {
	return goImage + ":" + Normalise(release) + g.Variant
}

// HasGoPins is true when the manifest pins Go at all. A repository that does
// not -- every consumer of this library -- has no Go pin for its copies to
// follow, so its `go-version:` inputs and `golang:` images are not judged.
func HasGoPins(manifest []ManifestEntry) bool {
	return slices.ContainsFunc(manifest, func(entry ManifestEntry) bool { return entry.Kind == KindGoToolchain })
}

// GoPin is the `go-toolchain` pin a copy of Go `release` follows: the one on the
// copy's release line, major and minor. Nil when no pin holds that line.
func GoPin(manifest []ManifestEntry, release string) *ManifestEntry {
	line := goLine(release)
	if line == "" {
		return nil
	}
	for index := range manifest {
		if manifest[index].Kind == KindGoToolchain && goLine(manifest[index].Current) == line {
			return &manifest[index]
		}
	}
	return nil
}

// goLineParts is how much of a Go release names its line: major and minor.
const goLineParts = 2

// goLine is a Go release's line: `1.27` for 1.27.2, and for 1.27.
func goLine(release string) string {
	parts := Parts(release)
	if len(parts) < goLineParts {
		return ""
	}
	return fmt.Sprintf("%d.%d", parts[0], parts[1])
}

// unpinnedGoLine is the drift row for a copy no Go pin holds the line of.
func unpinnedGoLine(path, inline, release string) Drift {
	return Drift{Name: KindGoToolchain, File: path, Inline: inline,
		Manifest: "no pin on the " + goLine(release) + " line"}
}

// FindGoDrift lists every copy of a Go release in `files` -- a `go-version:` or
// `GoTool@0` input, a `golang:` image -- that names another release than the
// pin of its line, and every one no pin holds the line of. Nothing, for a
// manifest with no Go pin.
func FindGoDrift(files []SourceText, manifest []ManifestEntry) []Drift {
	if !HasGoPins(manifest) {
		return nil
	}
	var drifts []Drift
	for _, file := range files {
		for _, pattern := range goReleaseCopies() {
			for _, match := range pattern.FindAllStringSubmatch(file.Text, -1) {
				drifts = append(drifts, goDrift(manifest, file.Path, match[1], match[1])...)
			}
		}
		images := make(map[string]string)
		ScanImages(file.Text, file.Dockerfile, images)
		for _, reference := range slices.Sorted(maps.Keys(images)) {
			if image, isGo := ParseGoImage(reference); isGo {
				name, _, _ := strings.Cut(reference, "@")
				drifts = append(drifts, goDrift(manifest, file.Path, name, image.Release)...)
			}
		}
	}
	return drifts
}

func goDrift(manifest []ManifestEntry, path, inline, release string) []Drift {
	pin := GoPin(manifest, release)
	switch {
	case pin == nil:
		return []Drift{unpinnedGoLine(path, inline, release)}
	case SameValue(pin.Var, release, pin.Current):
		return nil
	default:
		return []Drift{{Name: pin.Var, File: path, Inline: inline, Manifest: pin.Current}}
	}
}

// AlignGoCopies sets every `go-version:` and `GoTool@0` input in `text` to the
// release `targets` holds for its pin, written in full (`1.27` becomes
// `1.27.2`): a copy names the release the pin vouches for, never a range that
// installs whichever patch is newest that day. Pins are matched by line as
// `manifest` read before the run, so a pin moving to a new line takes its
// copies with it. A copy no pin holds the line of is left for drift to report.
func AlignGoCopies(text, path string, manifest []ManifestEntry, targets map[string]string) (string, []CopyChange) {
	var changes []CopyChange
	for _, pattern := range goReleaseCopies() {
		var builder strings.Builder
		last := 0
		for _, match := range pattern.FindAllStringSubmatchIndex(text, -1) {
			found := text[match[2]:match[3]]
			pin := GoPin(manifest, found)
			if pin == nil {
				continue
			}
			want := targets[pin.Var]
			if want == "" || SameValue(pin.Var, found, want) {
				continue
			}
			value := Restyle(found, want)
			changes = append(changes, CopyChange{
				Var: pin.Var, File: path, From: found, To: value, Drifted: !SameValue(pin.Var, found, pin.Current),
			})
			builder.WriteString(text[last:match[2]])
			builder.WriteString(value)
			last = match[3]
		}
		builder.WriteString(text[last:])
		text = builder.String()
	}
	return text, changes
}
