package repositories

import (
	"encoding/json"
	"io"
	"net/http"

	"github.com/rios0rios0/pipelines/global/scripts/tools/dependency-updates/internal/domain/repositories"
)

// Fixture is an offline run's upstream answers, keyed by the question:
//
//	"GET <url>"            a document: a JSON value, or a string for a text one
//	"SHA256 <url>"         the SHA-256 of what the URL serves
//	"<kind>:<coordinate>"  the newest release, or {"latest": ..., "releases": [...]}
//	"image:<reference>"    the digest an image tag resolves to now
//	"osv:<ecosystem>:<package>"  the package's advisories, in OSV's schema
//
// `null` answers 404. A question with no entry is a failed lookup, never an
// absent answer: the fixture is held to the same fail-safe rule as the network.
type Fixture map[string]json.RawMessage

// ParseFixture reads a fixture document.
func ParseFixture(content []byte) (Fixture, error) {
	var fixture Fixture
	if err := json.Unmarshal(content, &fixture); err != nil {
		return nil, err
	}
	return fixture, nil
}

// Answer is the raw answer to a question: NotFound for `null`, a lookup error
// for no entry at all.
func (f Fixture) Answer(key string) (json.RawMessage, error) {
	raw, found := f[key]
	if !found {
		return nil, repositories.NewLookupError("no fixture entry for %s", key)
	}
	if string(raw) == "null" {
		return nil, repositories.NewNotFoundError("%s -> HTTP 404", key)
	}
	return raw, nil
}

// FixtureTransport answers the transport's questions from a fixture.
type FixtureTransport struct {
	fixture Fixture
}

// NewFixtureTransport builds the offline transport.
func NewFixtureTransport(fixture Fixture) *FixtureTransport {
	return &FixtureTransport{fixture: fixture}
}

// Get answers `GET <url>`: a JSON string is the document's text, anything else
// is the document itself.
func (t *FixtureTransport) Get(url string, _ map[string]string, _ int64) ([]byte, error) {
	raw, err := t.fixture.Answer("GET " + url)
	if err != nil {
		return nil, err
	}
	var text string
	if json.Unmarshal(raw, &text) == nil {
		return []byte(text), nil
	}
	return raw, nil
}

// SHA256 answers `SHA256 <url>`.
func (t *FixtureTransport) SHA256(url string) (string, error) {
	raw, err := t.fixture.Answer("SHA256 " + url)
	if err != nil {
		return "", err
	}
	var digest string
	if json.Unmarshal(raw, &digest) != nil {
		return "", repositories.NewLookupError("fixture SHA256 %s is not a string", url)
	}
	return digest, nil
}

// Head is never asked offline: image digests are answered by `image:` entries.
func (t *FixtureTransport) Head(url string, _ map[string]string) (http.Header, error) {
	return nil, repositories.NewLookupError("no fixture entry for HEAD %s", url)
}

// Open is never asked offline: image scans are answered by `scan:` entries.
func (t *FixtureTransport) Open(url string, _ map[string]string) (io.ReadCloser, error) {
	return nil, repositories.NewLookupError("no fixture entry for OPEN %s", url)
}

// Post is never asked offline: advisories are answered by `osv:` entries.
func (t *FixtureTransport) Post(url string, _ []byte) ([]byte, error) {
	return nil, repositories.NewLookupError("no fixture entry for POST %s", url)
}
