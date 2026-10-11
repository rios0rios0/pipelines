package repositories_test

import (
	"context"
	"crypto/sha256"
	"crypto/tls"
	"encoding/hex"
	"io"
	"log/slog"
	"net"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/rios0rios0/pipelines/global/scripts/tools/dependency-updates/internal/domain/repositories"
	infrastructure "github.com/rios0rios0/pipelines/global/scripts/tools/dependency-updates/internal/infrastructure/repositories"
)

func tlsServer(t *testing.T, handler http.HandlerFunc) *httptest.Server {
	t.Helper()
	server := httptest.NewTLSServer(handler)
	t.Cleanup(server.Close)
	return server
}

// crossHostClient reaches `other.test` at `target`'s address, so a redirect can
// leave the original host without leaving the machine. Certificates are not
// checked: this is about which headers travel, not about TLS.
func crossHostClient(target *httptest.Server) *http.Client {
	address := target.Listener.Addr().String()
	return &http.Client{Transport: &http.Transport{
		TLSClientConfig: &tls.Config{InsecureSkipVerify: true},
		DialContext: func(ctx context.Context, network, host string) (net.Conn, error) {
			if strings.HasPrefix(host, "other.test:") {
				host = address
			}
			return (&net.Dialer{}).DialContext(ctx, network, host)
		},
	}}
}

func TestHTTPTransportRefusals(t *testing.T) {
	t.Parallel()

	t.Run("should refuse a URL that is not https without asking anything", func(t *testing.T) {
		t.Parallel()
		// given
		transport := infrastructure.NewHTTPTransport()

		// when
		_, err := transport.Get("http://example.test/document", nil, infrastructure.MaxDocumentBytes)

		// then
		require.Error(t, err)
		assert.Contains(t, err.Error(), "refusing a URL that is not https")
	})

	t.Run("should refuse a redirect away from https", func(t *testing.T) {
		t.Parallel()
		// given
		server := tlsServer(t, func(writer http.ResponseWriter, request *http.Request) {
			http.Redirect(writer, request, "http://example.test/downgraded", http.StatusFound)
		})
		transport := infrastructure.NewHTTPTransportWithClient(server.Client())

		// when
		_, err := transport.Get(server.URL+"/asset", nil, infrastructure.MaxDocumentBytes)

		// then
		require.Error(t, err)
		assert.Contains(t, err.Error(), "refused a redirect away from https")
	})

	t.Run("should answer a 404 as a definite not-found", func(t *testing.T) {
		t.Parallel()
		// given
		server := tlsServer(t, http.NotFound)
		transport := infrastructure.NewHTTPTransportWithClient(server.Client())

		// when
		_, err := transport.Get(server.URL+"/missing", nil, infrastructure.MaxDocumentBytes)

		// then
		assert.True(t, repositories.IsNotFound(err))
	})

	t.Run("should never read a rate limit as anything but a failed lookup", func(t *testing.T) {
		t.Parallel()
		// given
		server := tlsServer(t, func(writer http.ResponseWriter, _ *http.Request) {
			writer.WriteHeader(http.StatusTooManyRequests)
		})
		transport := infrastructure.NewHTTPTransportWithClient(server.Client())

		// when
		_, err := transport.Get(server.URL+"/api", nil, infrastructure.MaxDocumentBytes)

		// then
		require.Error(t, err)
		assert.False(t, repositories.IsNotFound(err))
		assert.Contains(t, err.Error(), "rate limited; set GITHUB_TOKEN")
	})

	t.Run("should refuse a document larger than its cap", func(t *testing.T) {
		t.Parallel()
		// given
		server := tlsServer(t, func(writer http.ResponseWriter, _ *http.Request) {
			_, _ = writer.Write([]byte(strings.Repeat("x", 20)))
		})
		transport := infrastructure.NewHTTPTransportWithClient(server.Client())

		// when
		_, err := transport.Get(server.URL+"/big", nil, 10)

		// then
		require.Error(t, err)
		assert.Contains(t, err.Error(), "larger than 10 bytes")
	})
}

func TestHTTPTransportRedirectHeaders(t *testing.T) {
	t.Parallel()

	t.Run("should drop the token when a redirect leaves the original host", func(t *testing.T) {
		t.Parallel()
		// given
		var received atomic.Value
		received.Store("unset")
		landing := tlsServer(t, func(writer http.ResponseWriter, request *http.Request) {
			received.Store(request.Header.Get("Authorization"))
			_, _ = writer.Write([]byte("asset"))
		})
		origin := tlsServer(t, func(writer http.ResponseWriter, request *http.Request) {
			port := landing.Listener.Addr().(*net.TCPAddr).Port
			http.Redirect(writer, request, "https://other.test:"+strconv.Itoa(port)+"/asset", http.StatusFound)
		})
		transport := infrastructure.NewHTTPTransportWithClient(crossHostClient(landing))

		// when
		_, err := transport.Get(
			origin.URL+"/download",
			map[string]string{"Authorization": "Bearer fixture-token-placeholder"},
			infrastructure.MaxDocumentBytes,
		)

		// then
		require.NoError(t, err)
		assert.Empty(t, received.Load(), "a token meant for one host never follows a redirect to another")
	})

	t.Run("should keep the token on a redirect within the same host", func(t *testing.T) {
		t.Parallel()
		// given
		var received atomic.Value
		var server *httptest.Server
		server = tlsServer(t, func(writer http.ResponseWriter, request *http.Request) {
			if request.URL.Path == "/start" {
				http.Redirect(writer, request, server.URL+"/end", http.StatusFound)
				return
			}
			received.Store(request.Header.Get("Authorization"))
		})
		transport := infrastructure.NewHTTPTransportWithClient(server.Client())

		// when
		_, err := transport.Get(
			server.URL+"/start",
			map[string]string{"Authorization": "Bearer fixture-token-placeholder"},
			infrastructure.MaxDocumentBytes,
		)

		// then
		require.NoError(t, err)
		assert.Equal(t, "Bearer fixture-token-placeholder", received.Load())
	})
}

func TestHTTPTransportContent(t *testing.T) {
	t.Parallel()

	t.Run("should hash what a URL serves while it streams", func(t *testing.T) {
		t.Parallel()
		// given
		server := tlsServer(t, func(writer http.ResponseWriter, _ *http.Request) {
			_, _ = writer.Write([]byte("release asset bytes"))
		})
		transport := infrastructure.NewHTTPTransportWithClient(server.Client())
		sum := sha256.Sum256([]byte("release asset bytes"))

		// when
		digest, err := transport.SHA256(server.URL + "/asset")

		// then
		require.NoError(t, err)
		assert.Equal(t, hex.EncodeToString(sum[:]), digest)
	})

	t.Run("should ask for one document once per run", func(t *testing.T) {
		t.Parallel()
		// given
		var calls atomic.Int32
		server := tlsServer(t, func(writer http.ResponseWriter, _ *http.Request) {
			calls.Add(1)
			_, _ = writer.Write([]byte(`{"tag_name": "v1.0.0"}`))
		})
		transport := infrastructure.NewHTTPTransportWithClient(server.Client())

		// when
		_, firstErr := transport.Get(server.URL+"/release", nil, infrastructure.MaxDocumentBytes)
		_, secondErr := transport.Get(server.URL+"/release", nil, infrastructure.MaxDocumentBytes)

		// then
		require.NoError(t, firstErr)
		require.NoError(t, secondErr)
		assert.Equal(t, int32(1), calls.Load())
	})
}

// failingServer answers `status` to its first `failures` requests and then
// echoes what it was sent; the counter is every request it was asked.
func failingServer(t *testing.T, status, failures int) (*httptest.Server, *atomic.Int32) {
	t.Helper()
	var asked atomic.Int32
	server := tlsServer(t, func(writer http.ResponseWriter, request *http.Request) {
		if int(asked.Add(1)) <= failures {
			writer.WriteHeader(status)
			return
		}
		body, _ := io.ReadAll(request.Body)
		_, _ = writer.Write(append([]byte("answered:"), body...))
	})
	return server, &asked
}

func quickRetries(client *http.Client) *infrastructure.HTTPTransport {
	return infrastructure.NewHTTPTransportWithClient(client).WithRetryBackoff(time.Millisecond)
}

func TestHTTPTransportRetries(t *testing.T) {
	t.Parallel()

	t.Run("should ask again after a gateway error and return the answer that follows", func(t *testing.T) {
		t.Parallel()
		// given
		server, asked := failingServer(t, http.StatusBadGateway, 1)
		transport := quickRetries(server.Client())

		// when
		content, err := transport.Get(server.URL+"/v1/vulns/GO-2026-1", nil, infrastructure.MaxDocumentBytes)

		// then
		require.NoError(t, err)
		assert.Equal(t, "answered:", string(content))
		assert.Equal(t, int32(2), asked.Load())
	})

	t.Run("should send the same body again when it asks a query again", func(t *testing.T) {
		t.Parallel()
		// given
		server, _ := failingServer(t, http.StatusServiceUnavailable, 2)
		transport := quickRetries(server.Client())

		// when
		content, err := transport.Post(server.URL+"/v1/querybatch", []byte(`{"queries":[]}`))

		// then
		require.NoError(t, err)
		assert.Equal(t, `answered:{"queries":[]}`, string(content))
	})

	t.Run("should give up after three attempts, as a failed lookup", func(t *testing.T) {
		t.Parallel()
		// given
		server, asked := failingServer(t, http.StatusServiceUnavailable, maxRequests)
		transport := quickRetries(server.Client())

		// when
		_, err := transport.Get(server.URL+"/v1/vulns/GO-2026-1", nil, infrastructure.MaxDocumentBytes)

		// then
		require.Error(t, err)
		assert.True(t, repositories.IsLookupError(err))
		assert.Contains(t, err.Error(), "HTTP 503")
		assert.Equal(t, int32(3), asked.Load())
	})

	t.Run("should not ask again after a rate limit, whose window is an hour", func(t *testing.T) {
		t.Parallel()
		// given
		server, asked := failingServer(t, http.StatusTooManyRequests, maxRequests)
		transport := quickRetries(server.Client())

		// when
		_, err := transport.Get(server.URL+"/repos/o/r/releases", nil, infrastructure.MaxDocumentBytes)

		// then
		require.Error(t, err)
		assert.Equal(t, int32(1), asked.Load())
	})

	t.Run("should not ask again after refusing a redirect", func(t *testing.T) {
		t.Parallel()
		// given
		var asked atomic.Int32
		server := tlsServer(t, func(writer http.ResponseWriter, request *http.Request) {
			asked.Add(1)
			http.Redirect(writer, request, "http://example.test/downgraded", http.StatusFound)
		})
		transport := quickRetries(server.Client())

		// when
		_, err := transport.Get(server.URL+"/asset", nil, infrastructure.MaxDocumentBytes)

		// then
		require.Error(t, err)
		assert.Equal(t, int32(1), asked.Load())
	})

	t.Run("should not ask again when the server's certificate is not trusted", func(t *testing.T) {
		t.Parallel()
		// given
		var connections atomic.Int32
		server := httptest.NewUnstartedServer(http.NotFoundHandler())
		// The refused handshake is the point; the server need not log it.
		server.Config.ErrorLog = slog.NewLogLogger(slog.DiscardHandler, slog.LevelError)
		server.Config.ConnState = func(_ net.Conn, state http.ConnState) {
			if state == http.StateNew {
				connections.Add(1)
			}
		}
		server.StartTLS()
		t.Cleanup(server.Close)
		transport := quickRetries(&http.Client{})

		// when
		_, err := transport.Get(server.URL+"/document", nil, infrastructure.MaxDocumentBytes)

		// then
		require.Error(t, err)
		assert.Equal(t, int32(1), connections.Load())
	})
}

// maxRequests is more failures than the transport will ever sit through.
const maxRequests = 10
