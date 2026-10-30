package entities

import (
	"maps"
	"regexp"
	"slices"
	"strconv"
	"strings"
)

// An image FOLLOWS a pin when the pin, not the registry, decides its tag: a
// `golang:<release>` image follows the Go pin of its release line, and an image
// of a repository a pin's `# image:` annotation names follows that pin, its tag
// being the pin's version and whatever variant the tag already carries.
//
// The digest check never moves a tag; it only asks whether the tag still
// resolves to the bytes pinned. For a tag naming one exact build that its
// publisher never rebuilds -- the SonarQube scanner's `12.1.0.3233_8.0.1` has
// resolved to one digest since the day it shipped, and `node:24.22.1-trixie`
// stops being rebuilt the day 24.22.2 ships -- that check stops firing, so
// without a pin the image stays on its release for good, while newer ones ship
// and nothing reports them.

// imageTag splits a tag into the release it names and the variant after it:
// `24.22.1-trixie` is release `24.22.1` with variant `-trixie`, and
// `12.1.0.3233_8.0.1` a release with none. A tag that starts with no release
// (`latest`, `bookworm`) is read whole as its release, so it never equals a
// pin's version and is moved to the tag the pin names.
var imageTag = regexp.MustCompile(`^(v?\d+(?:[._]\d+)*)((?:-[a-z0-9.]+)*)$`)

func splitImageTag(tag string) (string, string) {
	match := imageTag.FindStringSubmatch(tag)
	if match == nil {
		return tag, ""
	}
	return match[1], match[2]
}

// ImagePin is the pin whose `# image:` names the repository `reference` is an
// image of, and whose line its tag is on: a pin held with `track=` takes only
// the images of that line, so a Node pin held to 24 leaves `node:22-alpine` --
// a rolling tag the digest check already keeps current -- where it is. Nil when
// no pin does.
func ImagePin(manifest []ManifestEntry, reference string) *ManifestEntry {
	repository, tag := splitImageName(reference)
	release, _ := splitImageTag(tag)
	for index := range manifest {
		entry := &manifest[index]
		if entry.Image != "" && entry.Image == repository && (entry.Track == "" || InLine(release, entry.Track)) {
			return entry
		}
	}
	return nil
}

// unpinnedImageLine is the drift row for an image of a repository a pin names,
// tagged with one exact release of a line no pin holds: nothing would ever move
// it, which is how `.npm` sat on Node 16.14.0. A rolling tag of such a line
// (`node:22-alpine`) is no copy of a pin; the digest check watches it.
func unpinnedImageLine(manifest []ManifestEntry, path, reference string) (Drift, bool) {
	repository, tag := splitImageName(reference)
	release, _ := splitImageTag(tag)
	parts := Parts(release)
	for index := range manifest {
		entry := &manifest[index]
		if entry.Image != repository || entry.Track == "" {
			continue
		}
		width := len(Parts(entry.Track))
		if len(parts) < len(Parts(entry.Current)) || len(parts) < width {
			return Drift{}, false
		}
		line := make([]string, 0, width)
		for _, part := range parts[:width] {
			line = append(line, strconv.FormatInt(part, 10))
		}
		name, _, _ := strings.Cut(reference, "@")
		return Drift{Name: entry.Var, File: path, Inline: name,
			Manifest: "no pin on " + LineName(strings.Join(line, "."))}, true
	}
	return Drift{}, false
}

// FollowedPin is the pin the image `reference` follows, or nil.
func FollowedPin(manifest []ManifestEntry, reference string) *ManifestEntry {
	if image, isGo := ParseGoImage(reference); isGo {
		return GoPin(manifest, image.Release)
	}
	return ImagePin(manifest, reference)
}

// FollowerRelease is the release an image that follows a pin names: the Go
// release of a `golang:` tag, the release a tag of any other starts with.
func FollowerRelease(reference string) string {
	if image, isGo := ParseGoImage(reference); isGo {
		return image.Release
	}
	_, tag := splitImageName(reference)
	release, _ := splitImageTag(tag)
	return release
}

// FollowerName is the name the image `reference` takes when its pin moves to
// `release`: for an image pin, the tag's release becomes the pin's, in the
// spelling the tag already has (`v` or no `v`), and its variant stays. Only the
// prefix is kept, never `Restyle`'s major-only collapse, so a copy drifted to a
// rolling `:12` is moved to the exact tag the pin names rather than left where
// it is.
func FollowerName(reference, release string) string {
	if image, isGo := ParseGoImage(reference); isGo {
		return image.Name(release)
	}
	repository, tag := splitImageName(reference)
	current, variant := splitImageTag(tag)
	return repository + ":" + current[:len(current)-len(Normalise(current))] + Normalise(release) + variant
}

// FindImagePinDrift lists every image in `files` of a repository a pin names
// whose release is not the pin's version, and every exact tag of a line no pin
// holds. Nothing, for a manifest with no `# image:` pin -- as in every consumer
// of this library.
func FindImagePinDrift(files []SourceText, manifest []ManifestEntry) []Drift {
	if !slices.ContainsFunc(manifest, func(entry ManifestEntry) bool { return entry.Image != "" }) {
		return nil
	}
	var drifts []Drift
	for _, file := range files {
		images := make(map[string]string)
		ScanImages(file.Text, file.Dockerfile, images)
		for _, reference := range slices.Sorted(maps.Keys(images)) {
			pin := ImagePin(manifest, reference)
			if pin == nil {
				if drift, unpinned := unpinnedImageLine(manifest, file.Path, reference); unpinned {
					drifts = append(drifts, drift)
				}
				continue
			}
			if SameValue(pin.Var, FollowerRelease(reference), pin.Current) {
				continue
			}
			name, _, _ := strings.Cut(reference, "@")
			drifts = append(drifts, Drift{Name: pin.Var, File: file.Path, Inline: name, Manifest: pin.Current})
		}
	}
	return drifts
}

// splitImageName is an image reference's repository and tag, its digest set
// aside. The tag follows the last `:` after the last `/`, so a registry's port
// (`registry.example:5000/app`) is never read as one.
func splitImageName(reference string) (string, string) {
	name, _, _ := strings.Cut(reference, "@")
	colon := strings.LastIndex(name, ":")
	if colon < 0 || colon < strings.LastIndex(name, "/") {
		return name, ""
	}
	return name[:colon], name[colon+1:]
}
