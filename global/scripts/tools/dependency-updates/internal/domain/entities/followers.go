package entities

import (
	"maps"
	"slices"
	"strings"
)

// An image FOLLOWS a pin when the pin, not the registry, decides its tag: a
// `golang:<release>` image follows the Go pin of its release line, and an image
// of a repository a pin's `# image:` annotation names follows that pin, its tag
// being the pin's version.
//
// The digest check never moves a tag; it only asks whether the tag still
// resolves to the bytes pinned. For a tag naming one exact build that its
// publisher never rebuilds -- the SonarQube scanner's `12.1.0.3233_8.0.1` has
// resolved to one digest since the day it shipped -- that check never fires at
// all, so without a pin the image stays on its release for good, while newer
// ones ship and nothing reports them.

// ImagePin is the pin whose `# image:` names the repository `reference` is an
// image of; nil when no pin does.
func ImagePin(manifest []ManifestEntry, reference string) *ManifestEntry {
	repository, _ := splitImageName(reference)
	for index := range manifest {
		if manifest[index].Image != "" && manifest[index].Image == repository {
			return &manifest[index]
		}
	}
	return nil
}

// FollowedPin is the pin the image `reference` follows, or nil.
func FollowedPin(manifest []ManifestEntry, reference string) *ManifestEntry {
	if image, isGo := ParseGoImage(reference); isGo {
		return GoPin(manifest, image.Release)
	}
	return ImagePin(manifest, reference)
}

// FollowerRelease is the release an image that follows a pin names: the Go
// release of a `golang:` tag, the whole tag of any other.
func FollowerRelease(reference string) string {
	if image, isGo := ParseGoImage(reference); isGo {
		return image.Release
	}
	_, tag := splitImageName(reference)
	return tag
}

// FollowerName is the name the image `reference` takes when its pin moves to
// `release`: for an image pin, the tag IS the release, in the spelling the tag
// already has (`v` or no `v`). Only the prefix is kept, never `Restyle`'s
// major-only collapse, so a copy drifted to a rolling `:12` is moved to the
// exact tag the pin names rather than left where it is.
func FollowerName(reference, release string) string {
	if image, isGo := ParseGoImage(reference); isGo {
		return image.Name(release)
	}
	repository, tag := splitImageName(reference)
	return repository + ":" + tag[:len(tag)-len(Normalise(tag))] + Normalise(release)
}

// FindImagePinDrift lists every image in `files` of a repository a pin names
// whose tag is not the pin's version. Nothing, for a manifest with no `# image:`
// pin -- as in every consumer of this library.
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
			if pin == nil || SameValue(pin.Var, FollowerRelease(reference), pin.Current) {
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
