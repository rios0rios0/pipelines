package repositories

import (
	"encoding/json"
	"net/url"
	"regexp"
	"strings"

	"github.com/rios0rios0/pipelines/global/scripts/tools/dependency-updates/internal/domain/entities"
	"github.com/rios0rios0/pipelines/global/scripts/tools/dependency-updates/internal/domain/repositories"
)

// releaseAssetPattern is a GitHub release asset's download URL.
var releaseAssetPattern = regexp.MustCompile(
	`^https://github\.com/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)/releases/download/([^/]+)/([^/?#]+)$`)

const sha256Prefix = "sha256:"

// ReleaseArtifactsRepository fetches release assets and the documents beside
// them.
type ReleaseArtifactsRepository struct {
	transport Transport
}

// NewReleaseArtifactsRepository builds the repository.
func NewReleaseArtifactsRepository(transport Transport) *ReleaseArtifactsRepository {
	return &ReleaseArtifactsRepository{transport: transport}
}

// AssetDigest is the SHA-256 of the file at a URL, and where that answer came
// from. For a GitHub release asset it is the digest GitHub recorded when the
// asset was uploaded, which needs no download -- the CodeQL bundle alone is a
// gigabyte. A release published before GitHub recorded digests has none, and
// then, like any other URL, the file is downloaded and hashed.
func (r *ReleaseArtifactsRepository) AssetDigest(target string) (string, string, error) {
	if match := releaseAssetPattern.FindStringSubmatch(target); match != nil {
		recorded, err := r.recordedDigest(match[1], match[2], match[3])
		if err != nil || recorded != "" {
			return recorded, "GitHub's recorded digest of the release asset", err
		}
	}
	computed, err := r.transport.SHA256(target)
	if err != nil {
		return "", "", err
	}
	computed = strings.ToLower(computed)
	if !entities.SHA256Value.MatchString(computed) {
		return "", "", repositories.NewLookupError("%s -> %q is not a SHA-256", target, computed)
	}
	return computed, "SHA-256 of the downloaded asset", nil
}

func (r *ReleaseArtifactsRepository) recordedDigest(repository, escapedTag, escapedAsset string) (string, error) {
	tag, err := url.PathUnescape(escapedTag)
	if err != nil {
		tag = escapedTag
	}
	name, err := url.PathUnescape(escapedAsset)
	if err != nil {
		name = escapedAsset
	}
	content, err := r.transport.Get(gitHubAPI+"/repos/"+repository+"/releases/tags/"+url.PathEscape(tag),
		GitHubHeaders(), MaxDocumentBytes)
	if err != nil {
		return "", err
	}
	var release struct {
		Assets []struct {
			Name   string  `json:"name"`
			Digest *string `json:"digest"`
		} `json:"assets"`
	}
	if decodeErr := json.Unmarshal(content, &release); decodeErr != nil {
		return "", repositories.NewLookupError("release %s of %s -> not JSON: %s", tag, repository, decodeErr)
	}
	for _, asset := range release.Assets {
		if asset.Name != name {
			continue
		}
		if asset.Digest == nil {
			return "", nil
		}
		if recorded := strings.TrimPrefix(*asset.Digest, sha256Prefix); entities.SHA256Value.MatchString(recorded) {
			return recorded, nil
		}
		return "", nil
	}
	return "", repositories.NewNotFoundError("release %s of %s has no asset named %s", tag, repository, name)
}

// Text is a small document, such as a checksum manifest.
func (r *ReleaseArtifactsRepository) Text(target string) (string, error) {
	content, err := r.transport.Get(target, nil, MaxDocumentBytes)
	return string(content), err
}

// Content is a small file's bytes, such as a vendored configuration.
func (r *ReleaseArtifactsRepository) Content(target string) ([]byte, error) {
	return r.transport.Get(target, nil, MaxDocumentBytes)
}
