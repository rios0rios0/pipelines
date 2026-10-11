package repositories_test

import (
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/rios0rios0/pipelines/global/scripts/tools/dependency-updates/internal/domain/entities"
	infrastructure "github.com/rios0rios0/pipelines/global/scripts/tools/dependency-updates/internal/infrastructure/repositories"
)

// osvServer is a miniature OSV.dev: querybatch answers IDs, vulns answers the
// record, and query answers a package's records page by page.
func osvServer(t *testing.T, batch func(queries []map[string]any) any) *infrastructure.OSVAdvisoriesRepository {
	t.Helper()
	server := tlsServer(t, func(writer http.ResponseWriter, request *http.Request) {
		body, _ := io.ReadAll(request.Body)
		switch {
		case request.URL.Path == "/v1/querybatch":
			var document struct {
				Queries []map[string]any `json:"queries"`
			}
			_ = json.Unmarshal(body, &document)
			_ = json.NewEncoder(writer).Encode(batch(document.Queries))
		case strings.HasPrefix(request.URL.Path, "/v1/vulns/"):
			_ = json.NewEncoder(writer).Encode(map[string]any{
				"id": strings.TrimPrefix(request.URL.Path, "/v1/vulns/"), "summary": "a vulnerability",
				"database_specific": map[string]any{"severity": "HIGH"},
			})
		case request.URL.Path == "/v1/query" && !strings.Contains(string(body), "page_token"):
			_ = json.NewEncoder(writer).Encode(map[string]any{"vulns": []any{
				map[string]any{"id": "GHSA-mrrh-fwg8-r2c3", "affected": []any{map[string]any{
					"package": map[string]any{"ecosystem": "GitHub Actions", "name": "tj-actions/changed-files"},
					"ranges": []any{map[string]any{"type": "ECOSYSTEM", "events": []any{
						map[string]any{"introduced": "0"}, map[string]any{"fixed": "46.0.1"}}}},
				}}},
			}, "next_page_token": "page-2"})
		default:
			_ = json.NewEncoder(writer).Encode(map[string]any{"vulns": []any{}})
		}
	})
	return infrastructure.NewOSVAdvisoriesRepositoryAt(
		infrastructure.NewHTTPTransportWithClient(server.Client()),
		server.URL+"/v1",
	)
}

func pypi(version string) entities.AdvisoryQuery {
	return entities.AdvisoryQuery{
		Package: entities.Package{Ecosystem: entities.EcosystemPyPI, Name: "pdm"},
		Version: version,
	}
}

func TestOSVAdvisoriesRepository(t *testing.T) {
	t.Parallel()

	t.Run("should ask OSV about versions in one batch and read each record once", func(t *testing.T) {
		t.Parallel()
		// given
		repository := osvServer(t, func(queries []map[string]any) any {
			results := make([]any, 0, len(queries))
			for _, query := range queries {
				vulns := []any{}
				if query["version"] == "2.0.0" {
					vulns = append(vulns, map[string]any{"id": "PYSEC-2026-1"})
				}
				results = append(results, map[string]any{"vulns": vulns})
			}
			return map[string]any{"results": results}
		})

		// when
		found, err := repository.FindAll([]entities.AdvisoryQuery{pypi("2.0.0"), pypi("2.1.0")})

		// then
		require.NoError(t, err)
		require.Len(t, found[pypi("2.0.0")], 1)
		assert.Equal(t, "PYSEC-2026-1", found[pypi("2.0.0")][0].ID)
		assert.Equal(t, "HIGH", found[pypi("2.0.0")][0].Severity)
		assert.Empty(t, found[pypi("2.1.0")])
	})

	t.Run("should evaluate GitHub Actions here, following every page", func(t *testing.T) {
		t.Parallel()
		// given
		repository := osvServer(t, func([]map[string]any) any { return map[string]any{"results": []any{}} })
		compromised := entities.AdvisoryQuery{
			Package: entities.Package{Ecosystem: entities.EcosystemGitHubActions, Name: "tj-actions/changed-files"},
			Version: "v45.0.7",
		}
		fixed := compromised
		fixed.Version = "v46.0.1"

		// when
		found, err := repository.FindAll([]entities.AdvisoryQuery{compromised, fixed})

		// then
		require.NoError(t, err)
		assert.Equal(t, []string{"GHSA-mrrh-fwg8-r2c3"}, entities.AdvisoryIDs(found[compromised]))
		assert.Empty(t, found[fixed])
	})

	t.Run("should refuse an answer that does not match the questions", func(t *testing.T) {
		t.Parallel()
		// given
		repository := osvServer(t, func([]map[string]any) any { return map[string]any{"results": []any{}} })

		// when
		_, err := repository.FindAll([]entities.AdvisoryQuery{pypi("2.0.0")})

		// then
		require.Error(t, err)
		assert.Contains(t, err.Error(), "does not match the 1 queries asked")
	})

	t.Run("should refuse to assess a version on a partial list", func(t *testing.T) {
		t.Parallel()
		// given
		repository := osvServer(t, func([]map[string]any) any {
			return map[string]any{"results": []any{map[string]any{"vulns": []any{}, "next_page_token": "more"}}}
		})

		// when
		_, err := repository.FindAll([]entities.AdvisoryQuery{pypi("2.0.0")})

		// then
		require.Error(t, err)
		assert.Contains(t, err.Error(), "more advisories than one answer holds")
	})
}

func TestFixtureAdvisoriesRepository(t *testing.T) {
	t.Parallel()

	t.Run("should fail a package with no entry rather than call it clean", func(t *testing.T) {
		t.Parallel()
		// given
		repository := infrastructure.NewFixtureAdvisoriesRepository(infrastructure.Fixture{})

		// when
		_, err := repository.FindAll([]entities.AdvisoryQuery{pypi("2.0.0")})

		// then
		require.Error(t, err)
	})

	t.Run("should answer from the catch-all entry a test opts into", func(t *testing.T) {
		t.Parallel()
		// given
		repository := infrastructure.NewFixtureAdvisoriesRepository(
			infrastructure.Fixture{"osv:*": json.RawMessage("[]")},
		)

		// when
		found, err := repository.FindAll([]entities.AdvisoryQuery{pypi("2.0.0")})

		// then
		require.NoError(t, err)
		assert.Empty(t, found[pypi("2.0.0")])
	})
}
