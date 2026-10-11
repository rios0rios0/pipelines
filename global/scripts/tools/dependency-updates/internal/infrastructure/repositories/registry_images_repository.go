package repositories

import (
	"encoding/json"
	"fmt"
	"strings"

	"github.com/rios0rios0/pipelines/global/scripts/tools/dependency-updates/internal/domain/repositories"
)

const dockerHubRegistry = "registry-1.docker.io"

// manifestMediaTypes is every manifest shape a tag or digest can name: an index
// or a single-platform manifest, in OCI and Docker spellings.
func manifestMediaTypes() string {
	return strings.Join([]string{
		"application/vnd.oci.image.index.v1+json",
		"application/vnd.docker.distribution.manifest.list.v2+json",
		"application/vnd.oci.image.manifest.v1+json",
		"application/vnd.docker.distribution.manifest.v2+json",
	}, ",")
}

// SplitImage splits `[registry/]repository:tag[@digest]` into the registry
// host, the repository and the tag.
func SplitImage(reference string) (string, string, string) {
	head, _, _ := strings.Cut(reference, "@")
	repository, tag := head, "latest"
	if index := strings.LastIndex(head, ":"); index >= 0 {
		repository, tag = head[:index], head[index+1:]
	}
	first, rest, nested := strings.Cut(repository, "/")
	if nested && (strings.ContainsAny(first, ".:") || first == "localhost") {
		return first, rest, tag
	}
	if !strings.Contains(repository, "/") {
		repository = "library/" + repository
	}
	return dockerHubRegistry, repository, tag
}

func registryToken(transport Transport, registry, repository string) (string, error) {
	var target string
	switch registry {
	case "ghcr.io":
		target = "https://ghcr.io/token?service=ghcr.io&scope=repository:" + repository + ":pull"
	case dockerHubRegistry:
		target = "https://auth.docker.io/token?service=registry.docker.io&scope=repository:" + repository + ":pull"
	default:
		// mcr.microsoft.com and friends serve anonymously.
		return "", nil
	}
	content, err := transport.Get(target, nil, MaxDocumentBytes)
	if err != nil {
		return "", err
	}
	var answer struct {
		Token string `json:"token"`
	}
	if decodeErr := json.Unmarshal(content, &answer); decodeErr != nil {
		return "", repositories.NewLookupError("%s -> not JSON: %s", target, decodeErr)
	}
	return answer.Token, nil
}

func manifestHeaders(transport Transport, registry, repository string) (map[string]string, error) {
	headers := map[string]string{"Accept": manifestMediaTypes()}
	token, err := registryToken(transport, registry, repository)
	if err != nil {
		return nil, err
	}
	if token != "" {
		headers["Authorization"] = "Bearer " + token
	}
	return headers, nil
}

// imageDigest is the digest an image's tag resolves to now. Images are checked
// by DIGEST rather than by tag, because that is the question worth asking of a
// container: `python:3.13-slim` is rebuilt with patched system packages under
// the same tag, so "is there a newer tag" would miss every security rebuild,
// while "does this tag still resolve to the bytes we pinned" catches them all.
func imageDigest(transport Transport, reference string) (string, error) {
	registry, repository, tag := SplitImage(reference)
	headers, err := manifestHeaders(transport, registry, repository)
	if err != nil {
		return "", err
	}
	answer, err := transport.Head(fmt.Sprintf("https://%s/v2/%s/manifests/%s", registry, repository, tag), headers)
	if err != nil {
		return "", repositories.NewLookupError("%s -> %s", reference, err)
	}
	digest := answer.Get("Docker-Content-Digest")
	if digest == "" {
		return "", repositories.NewLookupError("%s -> registry returned no Docker-Content-Digest", reference)
	}
	return digest, nil
}

// RegistryImagesRepository asks container registries about digests.
type RegistryImagesRepository struct {
	transport Transport
	fixture   Fixture
}

// NewRegistryImagesRepository builds the repository; `fixture` makes it
// offline, answered by `exists:<reference>` entries.
func NewRegistryImagesRepository(transport Transport, fixture Fixture) *RegistryImagesRepository {
	return &RegistryImagesRepository{transport: transport, fixture: fixture}
}

// Exists is true when the repository a reference names holds the manifest its
// digest names. A digest is content-addressed, so this is what proves a pull
// request did not swap in bytes published under ANOTHER repository's name.
func (r *RegistryImagesRepository) Exists(reference string) (bool, error) {
	if r.fixture != nil {
		raw, err := r.fixture.Answer("exists:" + reference)
		if repositories.IsNotFound(err) {
			return false, nil
		}
		if err != nil {
			return false, err
		}
		var exists bool
		return exists, json.Unmarshal(raw, &exists)
	}
	registry, repository, _ := SplitImage(reference)
	_, digest, pinned := strings.Cut(reference, "@")
	if !pinned {
		return false, repositories.NewLookupError("%s carries no digest to look up", reference)
	}
	headers, err := manifestHeaders(r.transport, registry, repository)
	if err != nil {
		return false, err
	}
	_, err = r.transport.Head(fmt.Sprintf("https://%s/v2/%s/manifests/%s", registry, repository, digest), headers)
	if repositories.IsNotFound(err) {
		return false, nil
	}
	return err == nil, err
}
