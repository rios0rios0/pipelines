package repositories_test

import (
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/rios0rios0/pipelines/global/scripts/tools/dependency-updates/internal/domain/entities"
	infrastructure "github.com/rios0rios0/pipelines/global/scripts/tools/dependency-updates/internal/infrastructure/repositories"
)

// answers is a URL-keyed transport fixture: the live resolvers, offline.
func answers(t *testing.T, values map[string]any) infrastructure.Transport {
	t.Helper()
	fixture := infrastructure.Fixture{}
	for key, value := range values {
		raw, err := json.Marshal(value)
		require.NoError(t, err)
		fixture[key] = raw
	}
	return infrastructure.NewFixtureTransport(fixture)
}

func liveReleases(t *testing.T, values map[string]any) *infrastructure.UpstreamReleasesRepository {
	t.Helper()
	return infrastructure.NewUpstreamReleasesRepository(answers(t, values), nil)
}

func task(kind, coordinate, current string) *entities.Task {
	result := &entities.Task{Kind: kind, Coord: coordinate, Current: current}
	if entities.IsTaggedKind(kind) {
		result.Family, result.HasFamily = entities.TagFamily(current)
	}
	return result
}

func TestUpstreamReleasesRepositoryGitHub(t *testing.T) {
	t.Parallel()

	t.Run("should answer from the latest release when it is in the pin's release line", func(t *testing.T) {
		t.Parallel()
		// given
		repository := liveReleases(t, map[string]any{
			"GET https://api.github.com/repos/gitleaks/gitleaks/releases/latest": map[string]any{"tag_name": "v8.31.0"},
		})

		// when
		latest, err := repository.Latest(task(entities.KindGitHubRelease, "gitleaks/gitleaks", "8.30.1"))

		// then
		require.NoError(t, err)
		assert.Equal(t, "v8.31.0", latest)
	})

	t.Run("should look past a latest release from another release line", func(t *testing.T) {
		t.Parallel()
		// given
		repository := liveReleases(t, map[string]any{
			"GET https://api.github.com/repos/github/codeql-action/releases/latest": map[string]any{
				"tag_name": "codeql-bundle-v2.27.2"},
			"GET https://api.github.com/repos/github/codeql-action/releases?per_page=100": []any{
				map[string]any{"tag_name": "v4.38.3", "published_at": "2026-10-08T13:01:01Z"},
				map[string]any{"tag_name": "codeql-bundle-v2.27.2", "published_at": "2026-10-07T09:38:20Z"},
				map[string]any{"tag_name": "v4.38.2", "published_at": "2026-09-24T10:27:53Z"},
			},
		})

		// when
		latest, err := repository.Latest(task(entities.KindGitHubRelease, "github/codeql-action", "v4.37.7"))

		// then
		require.NoError(t, err)
		assert.Equal(t, "v4.38.3", latest)
	})

	t.Run("should date every release and leave out drafts", func(t *testing.T) {
		t.Parallel()
		// given
		repository := liveReleases(t, map[string]any{
			"GET https://api.github.com/repos/example/tool/releases?per_page=100": []any{
				map[string]any{"tag_name": "v2.0.0-rc.1", "published_at": "2026-10-09T00:00:00Z", "prerelease": true},
				map[string]any{"tag_name": "v1.3.0", "published_at": "2026-09-01T00:00:00Z"},
				map[string]any{"tag_name": "v1.4.0", "draft": true},
			},
		})

		// when
		releases, err := repository.List(task(entities.KindGitHubRelease, "example/tool", "1.2.3"))

		// then
		require.NoError(t, err)
		require.Len(t, releases, 2)
		assert.True(t, releases[0].Prerelease)
		assert.Equal(t, time.Date(2026, 9, 1, 0, 0, 0, 0, time.UTC), releases[1].Published)
	})

	t.Run("should read a page of releases larger than a document's cap", func(t *testing.T) {
		t.Parallel()
		// given
		notes := strings.Repeat("x", infrastructure.MaxDocumentBytes/64)
		page := make([]map[string]any, 0, 100)
		for minor := range 100 {
			page = append(page, map[string]any{
				"tag_name": fmt.Sprintf("v2.%d.0", minor), "published_at": "2026-10-16T11:33:37Z", "body": notes,
			})
		}
		listing, err := json.Marshal(page)
		require.NoError(t, err)
		require.Greater(t, len(listing), infrastructure.MaxDocumentBytes)
		server := tlsServer(t, func(writer http.ResponseWriter, request *http.Request) {
			if request.URL.RequestURI() != "/repos/golangci/golangci-lint/releases?per_page=100" {
				http.NotFound(writer, request)
				return
			}
			_, _ = writer.Write(listing)
		})
		repository := infrastructure.NewUpstreamReleasesRepository(
			infrastructure.NewHTTPTransportWithClient(crossHostClient(server, "api.github.com")), nil)

		// when
		releases, err := repository.List(task(entities.KindGitHubRelease, "golangci/golangci-lint", "2.14.0"))

		// then
		require.NoError(t, err)
		assert.Len(t, releases, 100)
	})
}

func TestUpstreamReleasesRepositoryRegistries(t *testing.T) {
	t.Parallel()

	t.Run("should treat a PyPI release whose every file is yanked as never to be installed", func(t *testing.T) {
		t.Parallel()
		// given
		repository := liveReleases(t, map[string]any{"GET https://pypi.org/pypi/pdm/json": map[string]any{
			"info": map[string]any{"version": "2.29.2"},
			"releases": map[string]any{
				"2.29.2": []any{map[string]any{"upload_time_iso_8601": "2026-09-20T10:00:00.123456Z"}},
				"2.29.1": []any{map[string]any{"upload_time_iso_8601": "2026-09-10T10:00:00Z", "yanked": true}},
			},
		}})

		// when
		latest, latestErr := repository.Latest(task(entities.KindPyPI, "pdm", "2.29.0"))
		releases, listErr := repository.List(task(entities.KindPyPI, "pdm", "2.29.0"))

		// then
		require.NoError(t, latestErr)
		require.NoError(t, listErr)
		assert.Equal(t, "2.29.2", latest)
		yanked := map[string]bool{}
		for _, release := range releases {
			yanked[release.Version] = release.Prerelease
		}
		assert.Equal(t, map[string]bool{"2.29.2": false, "2.29.1": true}, yanked)
	})

	t.Run("should date the pinned and every newer version, escaping capitals", func(t *testing.T) {
		t.Parallel()
		// given
		module := "https://proxy.golang.org/github.com/!cyclone!d!x/cyclonedx-gomod"
		repository := liveReleases(t, map[string]any{
			"GET " + module + "/@v/list":         "v1.11.0\nv1.12.0\nv1.13.0\n",
			"GET " + module + "/@v/v1.12.0.info": map[string]any{"Version": "v1.12.0", "Time": "2026-06-01T10:00:00Z"},
			"GET " + module + "/@v/v1.13.0.info": map[string]any{"Version": "v1.13.0", "Time": "2026-09-08T20:52:42Z"},
		})

		// when
		releases, err := repository.List(task(entities.KindGoProxy, "github.com/CycloneDX/cyclonedx-gomod", "v1.12.0"))

		// then
		require.NoError(t, err)
		published := map[string]string{}
		for _, release := range releases {
			published[release.Version] = release.Published.Format(time.DateOnly)
		}
		assert.Equal(t, map[string]string{"v1.13.0": "2026-09-08", "v1.12.0": "2026-06-01"}, published,
			"verifying a bump TO v1.12.0 has to find v1.12.0's age here")
	})
}

func TestUpstreamReleasesRepositoryGoToolchain(t *testing.T) {
	t.Parallel()

	module := "https://proxy.golang.org/golang.org/toolchain"
	listing := "v0.0.1-go1.26.9.linux-amd64\nv0.0.1-go1.27.0.linux-amd64\nv0.0.1-go1.27.1.linux-amd64\n" +
		"v0.0.1-go1.27.2.darwin-arm64\nv0.0.1-go1.27.2.linux-amd64\nv0.0.1-go1.28rc1.linux-amd64\n"
	goTask := func(current, line string) *entities.Task {
		return &entities.Task{
			Kind: entities.KindGoToolchain, Coord: "golang.org/toolchain", Current: current, Track: line,
		}
	}

	t.Run("should answer the newest final Go release in the pin's line", func(t *testing.T) {
		t.Parallel()
		// given
		repository := liveReleases(t, map[string]any{"GET " + module + "/@v/list": listing})

		// when
		current, previous := goTask("1.27.1", "1.27"), goTask("1.26.6", "1.26")
		latest, latestErr := repository.Latest(current)
		held, heldErr := repository.Latest(previous)

		// then
		require.NoError(t, latestErr)
		require.NoError(t, heldErr)
		assert.Equal(t, "1.27.2", latest, "a release candidate of the next line is neither final nor in the line")
		assert.Equal(t, "1.26.9", held)
	})

	t.Run("should date the pinned release and every newer one in its line", func(t *testing.T) {
		t.Parallel()
		// given
		info := func(version, published string) map[string]any {
			return map[string]any{"Version": "v0.0.1-go" + version + ".linux-amd64", "Time": published}
		}
		repository := liveReleases(t, map[string]any{
			"GET " + module + "/@v/list":                             listing,
			"GET " + module + "/@v/v0.0.1-go1.27.1.linux-amd64.info": info("1.27.1", "2026-08-28T16:20:06Z"),
			"GET " + module + "/@v/v0.0.1-go1.27.2.linux-amd64.info": info("1.27.2", "2026-10-02T20:28:03Z"),
		})

		// when
		releases, err := repository.List(goTask("1.27.1", "1.27"))

		// then
		require.NoError(t, err)
		published := map[string]string{}
		for _, release := range releases {
			published[release.Version] = release.Published.Format(time.DateOnly)
		}
		assert.Equal(t, map[string]string{"1.27.2": "2026-10-02", "1.27.1": "2026-08-28"}, published)
	})
}

func TestUpstreamReleasesRepositoryFixture(t *testing.T) {
	t.Parallel()

	t.Run("should read a bare version as a release old enough for any cooldown", func(t *testing.T) {
		t.Parallel()
		// given
		repository := infrastructure.NewUpstreamReleasesRepository(nil,
			infrastructure.Fixture{"pypi:pdm": json.RawMessage(`"2.29.2"`)})

		// when
		releases, err := repository.List(task(entities.KindPyPI, "pdm", "2.29.0"))

		// then
		require.NoError(t, err)
		require.Len(t, releases, 1)
		assert.Equal(t, int64(0), releases[0].Published.Unix())
	})
}

func TestGitHubSourceRepository(t *testing.T) {
	t.Parallel()

	tagObject, commit := "7777777777777777777777777777777777777777", "8888888888888888888888888888888888888888"

	t.Run("should follow an annotated tag to its commit", func(t *testing.T) {
		t.Parallel()
		// given
		repository := infrastructure.NewGitHubSourceRepository(answers(t, map[string]any{
			"GET https://api.github.com/repos/o/r/git/ref/tags/v4.0.0": map[string]any{
				"object": map[string]any{"type": "tag", "sha": tagObject}},
			"GET https://api.github.com/repos/o/r/git/tags/" + tagObject: map[string]any{
				"object": map[string]any{"type": "commit", "sha": commit}},
		}))

		// when
		sha, err := repository.TagCommit("o/r", "v4.0.0")

		// then
		require.NoError(t, err)
		assert.Equal(t, commit, sha)
	})

	t.Run("should refuse a tag that names something other than a commit", func(t *testing.T) {
		t.Parallel()
		// given
		repository := infrastructure.NewGitHubSourceRepository(answers(t, map[string]any{
			"GET https://api.github.com/repos/o/r/git/ref/tags/v4.0.0": map[string]any{
				"object": map[string]any{"type": "tree", "sha": commit}},
		}))

		// when
		_, err := repository.TagCommit("o/r", "v4.0.0")

		// then
		require.Error(t, err)
		assert.Contains(t, err.Error(), "points at tree, not a commit")
	})

	t.Run("should relate two commits the way the compare view does", func(t *testing.T) {
		t.Parallel()
		// given
		repository := infrastructure.NewGitHubSourceRepository(answers(t, map[string]any{
			"GET https://api.github.com/repos/o/r/compare/a...b?per_page=1": map[string]any{
				"status": "ahead", "ahead_by": 3, "files": []any{map[string]any{}, map[string]any{}}},
		}))

		// when
		comparison, err := repository.Compare("o/r", "a", "b")

		// then
		require.NoError(t, err)
		assert.Equal(t, entities.Comparison{Status: "ahead", AheadBy: 3, Files: 2}, comparison)
		assert.True(t, comparison.Descends())
	})
}

func TestSplitImage(t *testing.T) {
	t.Parallel()

	cases := map[string][3]string{
		"python:3.13-slim@sha256:abc":                {"registry-1.docker.io", "library/python", "3.13-slim"},
		"amazon/aws-cli:latest":                      {"registry-1.docker.io", "amazon/aws-cli", "latest"},
		"ghcr.io/rios0rios0/pipelines/awscli:latest": {"ghcr.io", "rios0rios0/pipelines/awscli", "latest"},
		"mcr.microsoft.com/dotnet/sdk:8.0":           {"mcr.microsoft.com", "dotnet/sdk", "8.0"},
		"localhost/tools":                            {"localhost", "tools", "latest"},
	}
	for reference, want := range cases {
		t.Run("should split "+reference, func(t *testing.T) {
			t.Parallel()
			// given / when
			registry, repository, tag := infrastructure.SplitImage(reference)

			// then
			assert.Equal(t, want, [3]string{registry, repository, tag})
		})
	}
}
