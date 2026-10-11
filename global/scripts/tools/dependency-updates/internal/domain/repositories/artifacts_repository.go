package repositories

// ArtifactsRepository fetches release artifacts and the documents beside them.
type ArtifactsRepository interface {
	// AssetDigest is the SHA-256 of the file at a URL and where that answer
	// came from: the digest GitHub recorded for a release asset, which needs no
	// download, or the hash of the downloaded bytes.
	AssetDigest(url string) (digest, source string, err error)
	// Text is a small document, such as a checksum manifest.
	Text(url string) (string, error)
	// Content is a small file's bytes, such as a vendored configuration.
	Content(url string) ([]byte, error)
}
