// Package repositories implements the dependency-update ports against the
// network, the file system and git -- and against an offline fixture, which
// answers the same transport questions so everything above the transport runs
// the same code in a test as it does against GitHub.
package repositories

import (
	"bytes"
	"context"
	"crypto/sha256"
	"crypto/tls"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"sync"
	"time"

	"github.com/rios0rios0/pipelines/global/scripts/tools/dependency-updates/internal/domain/repositories"
)

const (
	userAgent = "rios0rios0-pipelines-dependency-check"
	// documentTimeout bounds one API call or document.
	documentTimeout = 30 * time.Second
	// downloadTimeout bounds one asset download, which is hashed while it
	// streams and never written to disk.
	downloadTimeout = 10 * time.Minute
	// MaxDocumentBytes caps a JSON document or checksum manifest: a manifest
	// is a few kilobytes, and anything near this is not one.
	MaxDocumentBytes = 8 << 20
	// MaxPackumentBytes caps an npm package document, the one legitimately
	// large answer: knip's is 2.5 MB and grows with every release.
	MaxPackumentBytes = 64 << 20
	// maxDownloadBytes caps an asset that is downloaded to be hashed: only an
	// asset GitHub recorded no digest for, and those are small. The cap is what
	// makes a template pointed at the wrong file fail loudly instead of filling
	// the runner's disk.
	maxDownloadBytes = 512 << 20
	maxRedirects     = 10
	hashChunkBytes   = 1 << 20
	httpsScheme      = "https"
	// maxAttempts bounds how often one request is made. A gateway error or a
	// dropped connection is asked again, after retryBackoff and then twice
	// that: a 502 from the advisory database must not fail a gate that the same
	// question would pass seconds later.
	maxAttempts  = 3
	retryBackoff = 2 * time.Second
)

// errRedirectRefused marks a redirect this transport refused to follow: a
// decision, never worth asking again.
var errRedirectRefused = errors.New("refused a redirect")

// Transport is the network as the repositories see it.
type Transport interface {
	// Get fetches a document of at most `limit` bytes.
	Get(url string, headers map[string]string, limit int64) ([]byte, error)
	// SHA256 is the hash of what a URL serves.
	SHA256(url string) (string, error)
	// Head is a HEAD request's response headers.
	Head(url string, headers map[string]string) (http.Header, error)
	// Post sends a JSON document and returns the JSON answer.
	Post(url string, body []byte) ([]byte, error)
	// Open streams what a URL serves, for a body too large to hold -- an
	// image layer. The caller closes it.
	Open(url string, headers map[string]string) (io.ReadCloser, error)
}

// HTTPTransport is the live network: https only, in both directions.
type HTTPTransport struct {
	client  *http.Client
	backoff time.Duration
	cache   sync.Map
}

// NewHTTPTransport builds the live transport.
//
// A redirect is followed only to another https URL -- release downloads
// redirect to a CDN, and following one into plain HTTP would let whoever
// answers it choose the bytes being hashed -- and the Authorization header is
// dropped the moment a redirect leaves the original host, so a token meant for
// api.github.com never reaches whichever host a redirect names.
func NewHTTPTransport() *HTTPTransport {
	return NewHTTPTransportWithClient(&http.Client{})
}

// NewHTTPTransportWithClient builds the transport on `client` -- one trusting a
// test server's certificate, say -- with the redirect policy enforced on it.
func NewHTTPTransportWithClient(client *http.Client) *HTTPTransport {
	client.CheckRedirect = httpsOnlyRedirects
	return &HTTPTransport{client: client, backoff: retryBackoff}
}

// WithRetryBackoff sets the pause before the second attempt at a request; the
// third waits twice as long. The default is two seconds.
func (t *HTTPTransport) WithRetryBackoff(backoff time.Duration) *HTTPTransport {
	t.backoff = backoff
	return t
}

func httpsOnlyRedirects(request *http.Request, via []*http.Request) error {
	if len(via) >= maxRedirects {
		return fmt.Errorf("%w: stopped after %d redirects", errRedirectRefused, maxRedirects)
	}
	if request.URL.Scheme != httpsScheme {
		return fmt.Errorf("%w away from https", errRedirectRefused)
	}
	if request.URL.Hostname() != via[0].URL.Hostname() {
		request.Header.Del("Authorization")
	}
	return nil
}

func (t *HTTPTransport) do(
	ctx context.Context,
	method, target string,
	headers map[string]string,
	body []byte,
) (*http.Response, error) {
	parsed, err := url.Parse(target)
	if err != nil || parsed.Scheme != httpsScheme {
		return nil, repositories.NewLookupError("%s -> refusing a URL that is not https", target)
	}
	for attempt := 1; ; attempt++ {
		response, sendErr := t.send(ctx, method, target, headers, body)
		switch {
		case attempt < maxAttempts && transient(response, sendErr) && t.pause(ctx, attempt):
			if response != nil {
				_ = response.Body.Close()
			}
		case sendErr != nil:
			return nil, repositories.NewLookupError("%s -> %s", target, sendErr)
		case response.StatusCode >= http.StatusMultipleChoices:
			_ = response.Body.Close()
			return nil, statusError(target, response.StatusCode)
		default:
			return response, nil
		}
	}
}

func (t *HTTPTransport) send(
	ctx context.Context,
	method, target string,
	headers map[string]string,
	body []byte,
) (*http.Response, error) {
	request, err := http.NewRequestWithContext(ctx, method, target, bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	request.Header.Set("User-Agent", userAgent)
	for key, value := range headers {
		request.Header.Set(key, value)
	}
	return t.client.Do(request)
}

// transient is whether a failed attempt is worth repeating: a gateway error or
// a dropped connection usually clears in seconds. A rate limit does not -- its
// window is an hour -- and neither does an untrusted certificate, a refused
// redirect, or a request already out of time.
func transient(response *http.Response, err error) bool {
	if err != nil {
		var certificate *tls.CertificateVerificationError
		return !errors.Is(err, errRedirectRefused) && !errors.As(err, &certificate) &&
			!errors.Is(err, context.DeadlineExceeded) && !errors.Is(err, context.Canceled)
	}
	switch response.StatusCode {
	case http.StatusInternalServerError, http.StatusBadGateway, http.StatusServiceUnavailable,
		http.StatusGatewayTimeout:
		return true
	default:
		return false
	}
}

// pause waits out the backoff before the next attempt; false when the request
// runs out of time first.
func (t *HTTPTransport) pause(ctx context.Context, attempt int) bool {
	timer := time.NewTimer(t.backoff * time.Duration(attempt))
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return false
	case <-timer.C:
		return true
	}
}

func statusError(target string, status int) error {
	switch status {
	case http.StatusNotFound:
		return repositories.NewNotFoundError("%s -> HTTP 404", target)
	case http.StatusForbidden, http.StatusTooManyRequests:
		return repositories.NewLookupError("%s -> HTTP %d (rate limited; set GITHUB_TOKEN)", target, status)
	default:
		return repositories.NewLookupError("%s -> HTTP %d", target, status)
	}
}

// Get fetches a document, at most once per URL for the life of the run.
func (t *HTTPTransport) Get(target string, headers map[string]string, limit int64) ([]byte, error) {
	if cached, found := t.cache.Load(target); found {
		content, _ := cached.([]byte)
		return content, nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), documentTimeout)
	defer cancel()
	response, err := t.do(ctx, http.MethodGet, target, headers, nil)
	if err != nil {
		return nil, err
	}
	defer func() { _ = response.Body.Close() }()
	content, err := io.ReadAll(io.LimitReader(response.Body, limit+1))
	if err != nil {
		return nil, repositories.NewLookupError("%s -> %s", target, err)
	}
	if int64(len(content)) > limit {
		return nil, repositories.NewLookupError("%s -> larger than %d bytes", target, limit)
	}
	t.cache.Store(target, content)
	return content, nil
}

// SHA256 hashes what a URL serves while it streams.
func (t *HTTPTransport) SHA256(target string) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), downloadTimeout)
	defer cancel()
	response, err := t.do(ctx, http.MethodGet, target, nil, nil)
	if err != nil {
		return "", err
	}
	defer func() { _ = response.Body.Close() }()
	hash := sha256.New()
	written, err := io.CopyBuffer(hash, io.LimitReader(response.Body, maxDownloadBytes+1), make([]byte, hashChunkBytes))
	if err != nil {
		return "", repositories.NewLookupError("%s -> %s", target, err)
	}
	if written > maxDownloadBytes {
		return "", repositories.NewLookupError(
			"%s -> larger than %d bytes; is the template pointing at the right file?",
			target,
			maxDownloadBytes,
		)
	}
	return hex.EncodeToString(hash.Sum(nil)), nil
}

// Head returns a HEAD request's response headers.
func (t *HTTPTransport) Head(target string, headers map[string]string) (http.Header, error) {
	ctx, cancel := context.WithTimeout(context.Background(), documentTimeout)
	defer cancel()
	response, err := t.do(ctx, http.MethodHead, target, headers, nil)
	if err != nil {
		return nil, err
	}
	_ = response.Body.Close()
	return response.Header, nil
}

// Open streams what a URL serves; the download is bounded by time, and the
// caller bounds it by size.
func (t *HTTPTransport) Open(target string, headers map[string]string) (io.ReadCloser, error) {
	ctx, cancel := context.WithTimeout(context.Background(), downloadTimeout)
	//nolint:bodyclose // streamed: the caller closes the body, through the ReadCloser returned below
	response, err := t.do(ctx, http.MethodGet, target, headers, nil)
	if err != nil {
		cancel()
		return nil, err
	}
	return &cancelOnClose{ReadCloser: response.Body, cancel: cancel}, nil
}

// cancelOnClose releases a streamed request's deadline when its body is closed.
type cancelOnClose struct {
	io.ReadCloser

	cancel context.CancelFunc
}

func (c *cancelOnClose) Close() error {
	defer c.cancel()
	return c.ReadCloser.Close()
}

// Post sends a JSON document.
func (t *HTTPTransport) Post(target string, body []byte) ([]byte, error) {
	ctx, cancel := context.WithTimeout(context.Background(), documentTimeout)
	defer cancel()
	response, err := t.do(ctx, http.MethodPost, target, map[string]string{"Content-Type": "application/json"}, body)
	if err != nil {
		return nil, err
	}
	defer func() { _ = response.Body.Close() }()
	content, err := io.ReadAll(io.LimitReader(response.Body, MaxDocumentBytes+1))
	if err != nil {
		return nil, repositories.NewLookupError("%s -> %s", target, err)
	}
	if len(content) > MaxDocumentBytes {
		return nil, repositories.NewLookupError("%s -> larger than %d bytes", target, MaxDocumentBytes)
	}
	return content, nil
}
