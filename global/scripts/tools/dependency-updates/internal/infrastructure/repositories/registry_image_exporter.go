package repositories

import (
	"archive/tar"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"strings"

	"github.com/rios0rios0/pipelines/global/scripts/tools/dependency-updates/internal/domain/entities"
	"github.com/rios0rios0/pipelines/global/scripts/tools/dependency-updates/internal/domain/repositories"
)

const (
	exportOS           = "linux"
	exportArchitecture = "amd64"
	// maxImageBytes bounds one image's compressed layers. Every image pinned
	// here is far below it; a reference pointing at something far larger
	// fails loudly instead of filling the runner's disk.
	maxImageBytes = 4 << 30
	archiveMode   = 0o600
)

// NotScannableError is an image with no linux/amd64 content to scan -- a
// Windows image, say. It is reported as not scanned, never as clean.
type NotScannableError struct {
	Reason string
}

func (e *NotScannableError) Error() string {
	return e.Reason
}

type imageDescriptor struct {
	MediaType string `json:"mediaType"`
	Digest    string `json:"digest"`
	Size      int64  `json:"size"`
	Platform  *struct {
		OS           string `json:"os"`
		Architecture string `json:"architecture"`
	} `json:"platform"`
}

type imageManifest struct {
	Manifests []imageDescriptor `json:"manifests"`
	Config    imageDescriptor   `json:"config"`
	Layers    []imageDescriptor `json:"layers"`
}

// ImageExporter writes a registry image into a `docker save` archive, straight
// from the registry API: no container daemon, and no `docker pull`.
//
// Everything is content-addressed, and everything is checked: the manifest's
// SHA-256 must be the digest the reference pins, and every blob's SHA-256 and
// size must be the ones its descriptor names, verified while it streams. A
// registry, a CDN or a proxy answering with other bytes fails the export -- the
// same rule `verify-download.sh` holds every binary here to.
type ImageExporter struct {
	transport Transport
}

// NewImageExporter builds the exporter.
func NewImageExporter(transport Transport) *ImageExporter {
	return &ImageExporter{transport: transport}
}

// Export writes the linux/amd64 image `reference` (name@digest) to `path`.
func (e *ImageExporter) Export(reference, path string) error {
	registry, repository, _ := SplitImage(reference)
	_, digest, pinned := strings.Cut(reference, "@")
	if !pinned {
		return repositories.NewLookupError("%s carries no digest to export", reference)
	}
	headers, err := manifestHeaders(e.transport, registry, repository)
	if err != nil {
		return err
	}
	base := fmt.Sprintf("https://%s/v2/%s", registry, repository)
	manifest, err := e.manifest(base, digest, headers)
	if err != nil {
		return err
	}
	if len(manifest.Manifests) > 0 {
		platform := linuxManifest(manifest.Manifests)
		if platform == nil {
			return &NotScannableError{Reason: "it publishes no linux/amd64 image"}
		}
		if manifest, err = e.manifest(base, platform.Digest, headers); err != nil {
			return err
		}
	}
	if err = scannable(manifest); err != nil {
		return err
	}
	return e.write(base, headers, manifest, reference, path)
}

func (e *ImageExporter) manifest(base, digest string, headers map[string]string) (imageManifest, error) {
	var manifest imageManifest
	target := base + "/manifests/" + digest
	content, err := e.transport.Get(target, headers, MaxDocumentBytes)
	if err != nil {
		return manifest, err
	}
	if sha256Prefix+entities.SHA256Hex(content) != digest {
		return manifest, repositories.NewLookupError(
			"%s -> a manifest whose SHA-256 is not the digest asked for",
			target,
		)
	}
	if decodeErr := json.Unmarshal(content, &manifest); decodeErr != nil {
		return manifest, repositories.NewLookupError("%s -> not a manifest: %s", target, decodeErr)
	}
	return manifest, nil
}

func linuxManifest(manifests []imageDescriptor) *imageDescriptor {
	for index := range manifests {
		platform := manifests[index].Platform
		if platform != nil && platform.OS == exportOS && platform.Architecture == exportArchitecture {
			return &manifests[index]
		}
	}
	return nil
}

func scannable(manifest imageManifest) error {
	if manifest.Config.Digest == "" || len(manifest.Layers) == 0 {
		return &NotScannableError{Reason: "its manifest names no configuration or layers"}
	}
	var total int64
	for _, layer := range manifest.Layers {
		if strings.Contains(layer.MediaType, "foreign") || strings.Contains(layer.MediaType, "nondistributable") {
			return &NotScannableError{Reason: "it carries foreign (Windows) layers"}
		}
		total += layer.Size
	}
	if total > maxImageBytes {
		return repositories.NewLookupError(
			"its layers total %d bytes, beyond the %d this check downloads",
			total,
			maxImageBytes,
		)
	}
	return nil
}

// write streams the configuration and every layer into the archive, then the
// `manifest.json` that makes it one.
func (e *ImageExporter) write(
	base string,
	headers map[string]string,
	manifest imageManifest,
	reference, path string,
) error {
	file, err := os.OpenFile(path, os.O_CREATE|os.O_EXCL|os.O_WRONLY, archiveMode)
	if err != nil {
		return err
	}
	archive := tar.NewWriter(file)
	configName := strings.TrimPrefix(manifest.Config.Digest, sha256Prefix) + ".json"
	err = e.blob(base, headers, manifest.Config, configName, archive)
	layers := make([]string, 0, len(manifest.Layers))
	for _, layer := range manifest.Layers {
		if err != nil {
			break
		}
		name := strings.TrimPrefix(layer.Digest, sha256Prefix) + ".tar"
		err = e.blob(base, headers, layer, name, archive)
		layers = append(layers, name)
	}
	if err == nil {
		label, _, _ := strings.Cut(reference, "@")
		err = writeManifest(archive, configName, label, layers)
	}
	return errors.Join(err, archive.Close(), file.Close())
}

func (e *ImageExporter) blob(
	base string,
	headers map[string]string,
	descriptor imageDescriptor,
	name string,
	archive *tar.Writer,
) error {
	target := base + "/blobs/" + descriptor.Digest
	body, err := e.transport.Open(target, headers)
	if err != nil {
		return err
	}
	defer func() { _ = body.Close() }()
	if headerErr := archive.WriteHeader(
		&tar.Header{Name: name, Mode: archiveMode, Size: descriptor.Size},
	); headerErr != nil {
		return headerErr
	}
	hash := sha256.New()
	if _, copyErr := io.CopyN(io.MultiWriter(archive, hash), body, descriptor.Size); copyErr != nil {
		return repositories.NewLookupError(
			"%s -> shorter than the %d bytes its descriptor names: %s",
			target,
			descriptor.Size,
			copyErr,
		)
	}
	if extra, _ := body.Read(make([]byte, 1)); extra > 0 {
		return repositories.NewLookupError(
			"%s -> longer than the %d bytes its descriptor names",
			target,
			descriptor.Size,
		)
	}
	if sha256Prefix+hex.EncodeToString(hash.Sum(nil)) != descriptor.Digest {
		return repositories.NewLookupError("%s -> bytes whose SHA-256 is not the digest the manifest names", target)
	}
	return nil
}

func writeManifest(archive *tar.Writer, config, label string, layers []string) error {
	content, err := json.Marshal([]map[string]any{{"Config": config, "RepoTags": []string{label}, "Layers": layers}})
	if err != nil {
		return err
	}
	if headerErr := archive.WriteHeader(
		&tar.Header{Name: "manifest.json", Mode: archiveMode, Size: int64(len(content))},
	); headerErr != nil {
		return headerErr
	}
	_, err = archive.Write(content)
	return err
}
