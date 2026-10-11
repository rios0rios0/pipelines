package repositories_test

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	infrastructure "github.com/rios0rios0/pipelines/global/scripts/tools/dependency-updates/internal/infrastructure/repositories"
)

func digestOf(content []byte) string {
	sum := sha256.Sum256(content)
	return "sha256:" + hex.EncodeToString(sum[:])
}

// fakeImage is a one-layer image, its manifest, and an index naming it.
type fakeImage struct {
	blobs       map[string][]byte
	manifests   map[string][]byte
	indexDigest string
}

func newFakeImage(t *testing.T, layerMediaType string, platforms ...string) fakeImage {
	t.Helper()
	var layer bytes.Buffer
	zipper := gzip.NewWriter(&layer)
	archive := tar.NewWriter(zipper)
	content := []byte("Package: openssl\nVersion: 3.0.0\n")
	require.NoError(
		t,
		archive.WriteHeader(&tar.Header{Name: "var/lib/dpkg/status", Mode: 0o644, Size: int64(len(content))}),
	)
	_, _ = archive.Write(content)
	require.NoError(t, archive.Close())
	require.NoError(t, zipper.Close())
	config := []byte(`{"architecture":"amd64","os":"linux","rootfs":{"type":"layers"}}`)
	manifest, _ := json.Marshal(map[string]any{
		"schemaVersion": 2, "mediaType": "application/vnd.docker.distribution.manifest.v2+json",
		"config": map[string]any{"mediaType": "application/vnd.docker.container.image.v1+json",
			"digest": digestOf(config), "size": len(config)},
		"layers": []any{map[string]any{"mediaType": layerMediaType, "digest": digestOf(layer.Bytes()),
			"size": layer.Len()}},
	})
	entries := make([]any, 0, len(platforms))
	for _, platform := range platforms {
		os, architecture, _ := strings.Cut(platform, "/")
		entries = append(entries, map[string]any{"mediaType": "application/vnd.docker.distribution.manifest.v2+json",
			"digest": digestOf(manifest), "size": len(manifest),
			"platform": map[string]any{"os": os, "architecture": architecture}})
	}
	index, _ := json.Marshal(map[string]any{"schemaVersion": 2, "manifests": entries})
	return fakeImage{
		blobs:       map[string][]byte{digestOf(config): config, digestOf(layer.Bytes()): layer.Bytes()},
		manifests:   map[string][]byte{digestOf(manifest): manifest, digestOf(index): index},
		indexDigest: digestOf(index),
	}
}

// serve is a miniature registry for one repository, `acme/tool`.
func (f fakeImage) serve(t *testing.T) (*httptest.Server, string) {
	t.Helper()
	server := tlsServer(t, func(writer http.ResponseWriter, request *http.Request) {
		kind, digest, _ := strings.Cut(strings.TrimPrefix(request.URL.Path, "/v2/acme/tool/"), "/")
		store := map[string]map[string][]byte{"manifests": f.manifests, "blobs": f.blobs}[kind]
		content, found := store[digest]
		if !found {
			http.NotFound(writer, request)
			return
		}
		_, _ = writer.Write(content)
	})
	return server, strings.TrimPrefix(server.URL, "https://") + "/acme/tool:1.0@" + f.indexDigest
}

func archiveEntries(t *testing.T, path string) map[string][]byte {
	t.Helper()
	file, err := os.Open(path)
	require.NoError(t, err)
	defer func() { _ = file.Close() }()
	entries := map[string][]byte{}
	reader := tar.NewReader(file)
	for {
		header, nextErr := reader.Next()
		if errors.Is(nextErr, io.EOF) {
			return entries
		}
		require.NoError(t, nextErr)
		content, _ := io.ReadAll(reader)
		entries[header.Name] = content
	}
}

func TestImageExporter(t *testing.T) {
	t.Parallel()

	gzipLayer := "application/vnd.docker.image.rootfs.diff.tar.gzip"

	t.Run("should write the linux/amd64 image as a docker save archive", func(t *testing.T) {
		t.Parallel()
		// given
		image := newFakeImage(t, gzipLayer, "linux/arm64", "linux/amd64")
		server, reference := image.serve(t)
		path := filepath.Join(t.TempDir(), "image.tar")

		// when
		err := infrastructure.NewImageExporter(infrastructure.NewHTTPTransportWithClient(server.Client())).
			Export(reference, path)

		// then
		require.NoError(t, err)
		entries := archiveEntries(t, path)
		var manifest []struct {
			Config string   `json:"Config"`
			Layers []string `json:"Layers"`
		}
		require.NoError(t, json.Unmarshal(entries["manifest.json"], &manifest))
		require.Len(t, manifest, 1)
		assert.Contains(t, entries, manifest[0].Config)
		require.Len(t, manifest[0].Layers, 1)
		assert.Contains(t, entries, manifest[0].Layers[0])
	})

	t.Run("should refuse a blob whose bytes are not the digest the manifest names", func(t *testing.T) {
		t.Parallel()
		// given
		image := newFakeImage(t, gzipLayer, "linux/amd64")
		for digest, content := range image.blobs {
			if len(content) > 100 {
				tampered := bytes.Clone(content)
				tampered[len(tampered)-1] ^= 0xff
				image.blobs[digest] = tampered
			}
		}
		server, reference := image.serve(t)

		// when
		err := infrastructure.NewImageExporter(infrastructure.NewHTTPTransportWithClient(server.Client())).
			Export(reference, filepath.Join(t.TempDir(), "image.tar"))

		// then
		require.Error(t, err)
		assert.Contains(t, err.Error(), "SHA-256 is not the digest the manifest names")
	})

	t.Run("should report an image with no linux/amd64 build as not scannable", func(t *testing.T) {
		t.Parallel()
		// given
		image := newFakeImage(t, gzipLayer, "windows/amd64")
		server, reference := image.serve(t)

		// when
		err := infrastructure.NewImageExporter(infrastructure.NewHTTPTransportWithClient(server.Client())).
			Export(reference, filepath.Join(t.TempDir(), "image.tar"))

		// then
		var notScannable *infrastructure.NotScannableError
		require.ErrorAs(t, err, &notScannable)
		assert.Equal(t, "it publishes no linux/amd64 image", notScannable.Reason)
	})

	t.Run("should report an image with foreign layers as not scannable", func(t *testing.T) {
		t.Parallel()
		// given
		image := newFakeImage(t, "application/vnd.docker.image.rootfs.foreign.diff.tar.gzip", "linux/amd64")
		server, reference := image.serve(t)

		// when
		err := infrastructure.NewImageExporter(infrastructure.NewHTTPTransportWithClient(server.Client())).
			Export(reference, filepath.Join(t.TempDir(), "image.tar"))

		// then
		var notScannable *infrastructure.NotScannableError
		require.ErrorAs(t, err, &notScannable)
	})
}

// fakeScanner is an osv-scanner stand-in that writes `report` and exits with
// `status`, so the scanner's handling of each documented outcome is tested
// without the network.
func fakeScanner(t *testing.T, report string, status int) string {
	t.Helper()
	directory := t.TempDir()
	require.NoError(t, os.WriteFile(filepath.Join(directory, "report.json"), []byte(report), 0o600))
	script := "#!/bin/sh\ncp '" + filepath.Join(
		directory,
		"report.json",
	) + "' scan.json\nexit " + strconv.Itoa(
		status,
	) + "\n"
	path := filepath.Join(directory, "osv-scanner")
	writeExecutable(t, path, script)
	return path
}

// writeExecutable writes a script a test then runs. A parallel test forking
// while the file is open for writing hands its child the descriptor, and
// running the script then fails with "text file busy" until that child has
// exec'd in turn (golang/go#22315). Creating a descriptor under ForkLock held
// for reading is how package syscall keeps one out of a fork, which holds it
// for writing.
func writeExecutable(t *testing.T, path, script string) {
	t.Helper()
	syscall.ForkLock.RLock()
	defer syscall.ForkLock.RUnlock()
	require.NoError(t, os.WriteFile(path, []byte(script), 0o700))
}

// fakeInstaller is an `install.sh` stand-in that records each run in the file
// it returns second, then copies `scanner` to `binary` -- or, given a
// `failure`, says it and exits 1.
func fakeInstaller(t *testing.T, scanner, binary, failure string) (string, string) {
	t.Helper()
	directory := t.TempDir()
	runs := filepath.Join(directory, "runs")
	script := "#!/bin/sh\necho run >> '" + runs + "'\n"
	if failure != "" {
		script += "echo '" + failure + "' >&2\nexit 1\n"
	} else {
		script += "cp '" + scanner + "' '" + binary + "'\n"
	}
	path := filepath.Join(directory, "install.sh")
	writeExecutable(t, path, script)
	return path, runs
}

const scanReport = `{"results": [{"packages": [
  {"package": {"name": "openssl", "version": "3.0.15", "ecosystem": "Debian:13"},
   "groups": [{"ids": ["DEBIAN-CVE-2026-1"], "aliases": ["CVE-2026-1"], "max_severity": "7.5"}]},
  {"package": {"name": "left-pad", "version": "1.3.0", "ecosystem": "npm"},
   "groups": [{"ids": ["MAL-2026-1"], "aliases": [], "max_severity": ""}]}
]}]}`

func TestOSVImageScannerRepository(t *testing.T) {
	t.Parallel()

	t.Run("should report each group of identifiers as one finding of one package", func(t *testing.T) {
		t.Parallel()
		// given
		image := newFakeImage(t, "application/vnd.docker.image.rootfs.diff.tar.gzip", "linux/amd64")
		server, reference := image.serve(t)
		scanner := infrastructure.NewOSVImageScannerRepository(
			infrastructure.NewHTTPTransportWithClient(server.Client()), fakeScanner(t, scanReport, 1), "")

		// when
		scan, err := scanner.Scan(reference)

		// then
		require.NoError(t, err)
		require.Len(t, scan.Findings, 2)
		assert.Equal(t, []string{"CVE-2026-1", "DEBIAN-CVE-2026-1"}, scan.Findings[0].IDs)
		assert.Equal(t, "HIGH", scan.Findings[0].Severity)
		assert.Equal(t, "MALICIOUS", scan.Findings[1].Severity)
	})

	t.Run("should read 'no packages found' as an image with no findings", func(t *testing.T) {
		t.Parallel()
		// given
		image := newFakeImage(t, "application/vnd.docker.image.rootfs.diff.tar.gzip", "linux/amd64")
		server, reference := image.serve(t)
		scanner := infrastructure.NewOSVImageScannerRepository(
			infrastructure.NewHTTPTransportWithClient(server.Client()), fakeScanner(t, `{}`, 128), "")

		// when
		scan, err := scanner.Scan(reference)

		// then
		require.NoError(t, err)
		assert.Empty(t, scan.Findings)
	})

	t.Run("should fail when the scanner fails, never call the image clean", func(t *testing.T) {
		t.Parallel()
		// given
		image := newFakeImage(t, "application/vnd.docker.image.rootfs.diff.tar.gzip", "linux/amd64")
		server, reference := image.serve(t)
		scanner := infrastructure.NewOSVImageScannerRepository(
			infrastructure.NewHTTPTransportWithClient(server.Client()), fakeScanner(t, `{}`, 127), "")

		// when
		_, err := scanner.Scan(reference)

		// then
		require.Error(t, err)
	})

	t.Run("should say the scanner is missing when it is", func(t *testing.T) {
		t.Parallel()
		// given
		image := newFakeImage(t, "application/vnd.docker.image.rootfs.diff.tar.gzip", "linux/amd64")
		server, reference := image.serve(t)
		scanner := infrastructure.NewOSVImageScannerRepository(
			infrastructure.NewHTTPTransportWithClient(server.Client()), filepath.Join(t.TempDir(), "absent"), "")

		// when
		_, err := scanner.Scan(reference)

		// then
		require.Error(t, err)
		assert.Contains(t, err.Error(), "osv-scanner is not installed at")
	})

	t.Run("should install the scanner before the first scan, and only once", func(t *testing.T) {
		t.Parallel()
		// given
		image := newFakeImage(t, "application/vnd.docker.image.rootfs.diff.tar.gzip", "linux/amd64")
		server, reference := image.serve(t)
		binary := filepath.Join(t.TempDir(), "osv-scanner")
		installer, runs := fakeInstaller(t, fakeScanner(t, scanReport, 1), binary, "")
		scanner := infrastructure.NewOSVImageScannerRepository(
			infrastructure.NewHTTPTransportWithClient(server.Client()), binary, installer)

		// when
		scan, err := scanner.Scan(reference)
		_, _ = scanner.Scan(strings.Replace(reference, "acme/tool", "acme/other", 1))

		// then
		require.NoError(t, err)
		assert.Len(t, scan.Findings, 2)
		recorded, readErr := os.ReadFile(runs)
		require.NoError(t, readErr)
		assert.Equal(t, "run\n", string(recorded), "the installer runs once per run, not once per image")
	})

	t.Run("should fail the scan, in the installer's own words, when it cannot install", func(t *testing.T) {
		t.Parallel()
		// given
		image := newFakeImage(t, "application/vnd.docker.image.rootfs.diff.tar.gzip", "linux/amd64")
		server, reference := image.serve(t)
		binary := filepath.Join(t.TempDir(), "osv-scanner")
		installer, _ := fakeInstaller(t, "", binary, "ERROR: checksum mismatch")
		scanner := infrastructure.NewOSVImageScannerRepository(
			infrastructure.NewHTTPTransportWithClient(server.Client()), binary, installer)

		// when
		_, err := scanner.Scan(reference)

		// then
		require.Error(t, err)
		assert.Contains(t, err.Error(), "installing osv-scanner")
		assert.Contains(t, err.Error(), "ERROR: checksum mismatch")
	})
}
