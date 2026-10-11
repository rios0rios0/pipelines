package repositories

import (
	"encoding/json"
	"net/url"
	"os"
	"regexp"
	"strings"
	"time"

	"github.com/rios0rios0/pipelines/global/scripts/tools/dependency-updates/internal/domain/entities"
	"github.com/rios0rios0/pipelines/global/scripts/tools/dependency-updates/internal/domain/repositories"
)

const (
	gitHubAPI = "https://api.github.com"
	// reposPath leads every repository's resource on a GitHub API.
	reposPath   = "/repos/"
	npmRegistry = "https://registry.npmjs.org/"
	// goProxyInfoBudget bounds the `.info` lookups one Go module's listing may
	// cost: the module proxy dates each version separately.
	goProxyInfoBudget = 20
)

// goProxyCapital is how the module proxy escapes an upper-case letter: it
// lower-cases module paths, so `github.com/CycloneDX/...` is requested as
// `github.com/!cyclone!d!x/...`.
var goProxyCapital = regexp.MustCompile(`[A-Z]`)

// GitHubHeaders are the headers every api.github.com call carries. Roughly
// forty of the lookups hit it, and it allows 60 requests an hour
// unauthenticated, so a token is what keeps a run from failing part-way through
// as "lookup error".
func GitHubHeaders() map[string]string {
	headers := map[string]string{"Accept": "application/vnd.github+json"}
	token := os.Getenv("GITHUB_TOKEN")
	if token == "" {
		token = os.Getenv("GH_TOKEN")
	}
	if token != "" {
		headers["Authorization"] = "Bearer " + token
	}
	return headers
}

// UpstreamReleasesRepository answers what upstreams have released, live or
// from a fixture's `<kind>:<coordinate>` entries.
type UpstreamReleasesRepository struct {
	transport Transport
	fixture   Fixture
}

// NewUpstreamReleasesRepository builds the live repository; `fixture` makes it
// offline.
func NewUpstreamReleasesRepository(transport Transport, fixture Fixture) *UpstreamReleasesRepository {
	return &UpstreamReleasesRepository{transport: transport, fixture: fixture}
}

// fixtureReleases is the object form of a fixture entry.
type fixtureReleases struct {
	Latest   string `json:"latest"`
	Releases []struct {
		Version    string `json:"version"`
		Published  string `json:"published"`
		Prerelease bool   `json:"prerelease"`
	} `json:"releases"`
}

// Latest is upstream's newest release, or an image tag's digest.
func (r *UpstreamReleasesRepository) Latest(task *entities.Task) (string, error) {
	if r.fixture != nil {
		answer, err := r.fixtureEntry(task)
		return answer.Latest, err
	}
	if task.Kind == entities.KindImage {
		return imageDigest(r.transport, task.Coord)
	}
	switch task.Kind {
	case entities.KindGitHubRelease:
		return r.latestGitHubRelease(task)
	case entities.KindGitHubTag:
		return r.newestTag(gitHubAPI+reposPath+task.Coord+"/tags?per_page=100", task)
	case entities.KindGitLabTag:
		return r.newestTag(gitLabProject(task.Coord)+"/repository/tags?per_page=100", task)
	case entities.KindPyPI:
		return r.latestPyPI(task)
	case entities.KindNpm:
		return r.latestNpm(task)
	case entities.KindRubyGems:
		return r.latestRubyGems(task)
	case entities.KindGoProxy:
		return r.latestGoProxy(task)
	}
	return "", repositories.NewLookupError("unknown upstream kind '%s'", task.Kind)
}

// List is every release the task could move to, with its publication date.
func (r *UpstreamReleasesRepository) List(task *entities.Task) ([]entities.Release, error) {
	if r.fixture != nil {
		return r.fixtureList(task)
	}
	switch task.Kind {
	case entities.KindGitHubRelease:
		return r.listGitHubReleases(task)
	case entities.KindGitHubTag:
		return r.listTags(gitHubAPI+reposPath+task.Coord+"/tags?per_page=100", task)
	case entities.KindGitLabTag:
		return r.listGitLabReleases(task)
	case entities.KindPyPI:
		return r.listPyPI(task)
	case entities.KindNpm:
		return r.listNpm(task)
	case entities.KindRubyGems:
		return r.listRubyGems(task)
	case entities.KindGoProxy:
		return r.listGoProxy(task)
	}
	return nil, repositories.NewLookupError("unknown upstream kind '%s'", task.Kind)
}

func (r *UpstreamReleasesRepository) fixtureEntry(task *entities.Task) (fixtureReleases, error) {
	key := task.Kind + ":" + task.Coord
	raw, err := r.fixture.Answer(key)
	if err != nil {
		return fixtureReleases{}, err
	}
	var answer fixtureReleases
	if json.Unmarshal(raw, &answer.Latest) == nil {
		return answer, nil
	}
	if json.Unmarshal(raw, &answer) != nil {
		return fixtureReleases{}, repositories.NewLookupError("fixture %s is neither a version nor a release list", key)
	}
	return answer, nil
}

// fixtureList is the object form's releases, or -- for the plain form -- the
// latest release alone, published at the epoch: a fixture that names only a
// version means a release old enough for any cooldown.
func (r *UpstreamReleasesRepository) fixtureList(task *entities.Task) ([]entities.Release, error) {
	answer, err := r.fixtureEntry(task)
	if err != nil {
		return nil, err
	}
	if answer.Releases == nil {
		return []entities.Release{{Version: answer.Latest, Published: time.Unix(0, 0).UTC()}}, nil
	}
	releases := make([]entities.Release, 0, len(answer.Releases))
	for _, release := range answer.Releases {
		releases = append(releases, entities.Release{
			Version: release.Version, Published: parseTime(release.Published), Prerelease: release.Prerelease,
		})
	}
	return releases, nil
}

func (r *UpstreamReleasesRepository) getJSON(target string, headers map[string]string, limit int64, into any) error {
	content, err := r.transport.Get(target, headers, limit)
	if err != nil {
		return err
	}
	if decodeErr := json.Unmarshal(content, into); decodeErr != nil {
		return repositories.NewLookupError("%s -> not JSON: %s", target, decodeErr)
	}
	return nil
}

type gitHubRelease struct {
	TagName     string `json:"tag_name"`
	PublishedAt string `json:"published_at"`
	Draft       bool   `json:"draft"`
	Prerelease  bool   `json:"prerelease"`
}

// latestGitHubRelease answers almost every pin with the fast path. It is wrong
// only for a repository publishing two release lines, or a pin held inside a
// major: GoReleaser 1.x needs the newest release WITHIN 1.x, or the check
// reports a migration as an update every run, forever.
func (r *UpstreamReleasesRepository) latestGitHubRelease(task *entities.Task) (string, error) {
	if task.TrackMajor == "" {
		var latest gitHubRelease
		if err := r.getJSON(
			gitHubAPI+reposPath+task.Coord+"/releases/latest",
			GitHubHeaders(),
			MaxDocumentBytes,
			&latest,
		); err != nil {
			return "", err
		}
		if family, found := entities.TagFamily(latest.TagName); !task.HasFamily || (found && family == task.Family) {
			return latest.TagName, nil
		}
	}
	releases, err := r.listGitHubReleases(task)
	if err != nil {
		return "", err
	}
	best := newest(releases, task)
	if best == "" {
		return "", repositories.NewLookupError("no release found for %s%s", task.Coord, qualifiers(task))
	}
	return best, nil
}

func (r *UpstreamReleasesRepository) listGitHubReleases(task *entities.Task) ([]entities.Release, error) {
	var listed []gitHubRelease
	if err := r.getJSON(
		gitHubAPI+reposPath+task.Coord+"/releases?per_page=100",
		GitHubHeaders(),
		MaxDocumentBytes,
		&listed,
	); err != nil {
		return nil, err
	}
	releases := make([]entities.Release, 0, len(listed))
	for _, release := range listed {
		if release.Draft {
			continue
		}
		releases = append(releases, entities.Release{
			Version: release.TagName, Published: parseTime(release.PublishedAt), Prerelease: release.Prerelease,
		})
	}
	return releases, nil
}

func (r *UpstreamReleasesRepository) newestTag(target string, task *entities.Task) (string, error) {
	releases, err := r.listTags(target, task)
	if err != nil {
		return "", err
	}
	best := newest(releases, task)
	if best == "" {
		return "", repositories.NewLookupError("no semver-shaped tag found for %s%s", task.Coord, qualifiers(task))
	}
	return best, nil
}

// listTags reads a tags listing. Tags carry no publication date, so a pin
// tracking tags never satisfies a cooldown on its own: it needs `cooldown=0`,
// which is a decision written where review sees it.
func (r *UpstreamReleasesRepository) listTags(target string, _ *entities.Task) ([]entities.Release, error) {
	var tags []struct {
		Name string `json:"name"`
	}
	if err := r.getJSON(target, gitHubHeadersFor(target), MaxDocumentBytes, &tags); err != nil {
		return nil, err
	}
	releases := make([]entities.Release, 0, len(tags))
	for _, tag := range tags {
		releases = append(releases, entities.Release{Version: tag.Name})
	}
	return releases, nil
}

func gitHubHeadersFor(target string) map[string]string {
	if strings.HasPrefix(target, gitHubAPI+"/") {
		return GitHubHeaders()
	}
	return nil
}

func gitLabProject(project string) string {
	return "https://gitlab.com/api/v4/projects/" + url.PathEscape(project)
}

func (r *UpstreamReleasesRepository) listGitLabReleases(task *entities.Task) ([]entities.Release, error) {
	var listed []struct {
		TagName    string `json:"tag_name"`
		ReleasedAt string `json:"released_at"`
	}
	if err := r.getJSON(
		gitLabProject(task.Coord)+"/releases?per_page=100",
		nil,
		MaxDocumentBytes,
		&listed,
	); err != nil {
		return nil, err
	}
	releases := make([]entities.Release, 0, len(listed))
	for _, release := range listed {
		releases = append(
			releases,
			entities.Release{Version: release.TagName, Published: parseTime(release.ReleasedAt)},
		)
	}
	return releases, nil
}

type pyPIProject struct {
	Info struct {
		Version string `json:"version"`
	} `json:"info"`
	Releases map[string][]struct {
		UploadTime string `json:"upload_time_iso_8601"`
		Yanked     bool   `json:"yanked"`
	} `json:"releases"`
}

func (r *UpstreamReleasesRepository) pyPI(task *entities.Task) (pyPIProject, error) {
	var project pyPIProject
	err := r.getJSON("https://pypi.org/pypi/"+task.Coord+"/json", nil, MaxDocumentBytes, &project)
	return project, err
}

func (r *UpstreamReleasesRepository) latestPyPI(task *entities.Task) (string, error) {
	project, err := r.pyPI(task)
	if err != nil {
		return "", err
	}
	if task.TrackMajor == "" {
		return project.Info.Version, nil
	}
	releases, _ := r.listPyPI(task)
	if best := newest(releases, task); best != "" {
		return best, nil
	}
	return "", repositories.NewLookupError("no %s release within major %s", task.Coord, task.TrackMajor)
}

// listPyPI dates each release by its first upload. A release whose every file
// is yanked is treated as a pre-release: PyPI itself will not install it.
func (r *UpstreamReleasesRepository) listPyPI(task *entities.Task) ([]entities.Release, error) {
	project, err := r.pyPI(task)
	if err != nil {
		return nil, err
	}
	releases := make([]entities.Release, 0, len(project.Releases))
	for version, files := range project.Releases {
		var (
			published time.Time
			yanked    = len(files) > 0
		)
		for _, file := range files {
			uploaded := parseTime(file.UploadTime)
			if published.IsZero() || (!uploaded.IsZero() && uploaded.Before(published)) {
				published = uploaded
			}
			yanked = yanked && file.Yanked
		}
		releases = append(releases, entities.Release{Version: version, Published: published, Prerelease: yanked})
	}
	return releases, nil
}

type npmPackument struct {
	DistTags map[string]string          `json:"dist-tags"`
	Versions map[string]json.RawMessage `json:"versions"`
	Time     map[string]string          `json:"time"`
}

func (r *UpstreamReleasesRepository) latestNpm(task *entities.Task) (string, error) {
	if task.TrackMajor == "" {
		var latest struct {
			Version string `json:"version"`
		}
		err := r.getJSON(npmRegistry+task.Coord+"/latest", nil, MaxDocumentBytes, &latest)
		return latest.Version, err
	}
	var packument npmPackument
	if err := r.getJSON(npmRegistry+task.Coord, nil, MaxPackumentBytes, &packument); err != nil {
		return "", err
	}
	releases := make([]entities.Release, 0, len(packument.Versions))
	for version := range packument.Versions {
		releases = append(releases, entities.Release{Version: version})
	}
	if best := newest(releases, task); best != "" {
		return best, nil
	}
	return packument.DistTags["latest"], nil
}

func (r *UpstreamReleasesRepository) listNpm(task *entities.Task) ([]entities.Release, error) {
	var packument npmPackument
	if err := r.getJSON(npmRegistry+task.Coord, nil, MaxPackumentBytes, &packument); err != nil {
		return nil, err
	}
	releases := make([]entities.Release, 0, len(packument.Versions))
	for version := range packument.Versions {
		releases = append(releases, entities.Release{Version: version, Published: parseTime(packument.Time[version])})
	}
	return releases, nil
}

func (r *UpstreamReleasesRepository) latestRubyGems(task *entities.Task) (string, error) {
	var gem struct {
		Version string `json:"version"`
	}
	err := r.getJSON("https://rubygems.org/api/v1/gems/"+task.Coord+".json", nil, MaxDocumentBytes, &gem)
	return gem.Version, err
}

func (r *UpstreamReleasesRepository) listRubyGems(task *entities.Task) ([]entities.Release, error) {
	var listed []struct {
		Number     string `json:"number"`
		CreatedAt  string `json:"created_at"`
		Prerelease bool   `json:"prerelease"`
	}
	if err := r.getJSON(
		"https://rubygems.org/api/v1/versions/"+task.Coord+".json",
		nil,
		MaxDocumentBytes,
		&listed,
	); err != nil {
		return nil, err
	}
	releases := make([]entities.Release, 0, len(listed))
	for _, version := range listed {
		releases = append(releases, entities.Release{
			Version: version.Number, Published: parseTime(version.CreatedAt), Prerelease: version.Prerelease,
		})
	}
	return releases, nil
}

type goProxyInfo struct {
	Version string `json:"Version"`
	Time    string `json:"Time"`
}

func goProxyModule(module string) string {
	return "https://proxy.golang.org/" + goProxyCapital.ReplaceAllStringFunc(module, func(capital string) string {
		return "!" + strings.ToLower(capital)
	})
}

func (r *UpstreamReleasesRepository) latestGoProxy(task *entities.Task) (string, error) {
	var info goProxyInfo
	err := r.getJSON(goProxyModule(task.Coord)+"/@latest", nil, MaxDocumentBytes, &info)
	return info.Version, err
}

// listGoProxy dates the pinned version and every newer one, newest first, one
// `.info` each -- the proxy publishes no dated listing. The pinned version is
// dated too: verifying a pull request asks how old the version it moves TO is,
// and that version is the pin there.
func (r *UpstreamReleasesRepository) listGoProxy(task *entities.Task) ([]entities.Release, error) {
	content, err := r.transport.Get(goProxyModule(task.Coord)+"/@v/list", nil, MaxDocumentBytes)
	if err != nil {
		return nil, err
	}
	var versions []entities.Release
	for line := range strings.FieldsSeq(string(content)) {
		if !entities.IsNewer(line, task.Current) {
			versions = append(versions, entities.Release{Version: line})
		}
	}
	entities.NewestFirst(versions)
	releases := make([]entities.Release, 0, min(len(versions), goProxyInfoBudget))
	for _, version := range versions[:min(len(versions), goProxyInfoBudget)] {
		var info goProxyInfo
		target := goProxyModule(task.Coord) + "/@v/" + version.Version + ".info"
		if infoErr := r.getJSON(target, nil, MaxDocumentBytes, &info); infoErr != nil {
			return nil, infoErr
		}
		releases = append(releases, entities.Release{Version: version.Version, Published: parseTime(info.Time)})
	}
	return releases, nil
}

// newest is the highest semver-shaped release inside the task's release line
// and, when held, its major.
func newest(releases []entities.Release, task *entities.Task) string {
	best := ""
	for _, release := range releases {
		if inReleaseLine(release, task) && (best == "" || entities.CompareVersions(release.Version, best) > 0) {
			best = release.Version
		}
	}
	return best
}

// inReleaseLine is true for a final, semver-shaped release in the task's
// release line and, when held, its major.
func inReleaseLine(release entities.Release, task *entities.Task) bool {
	if release.Prerelease || len(entities.Parts(release.Version)) == 0 {
		return false
	}
	if task.HasFamily && entities.IsTaggedKind(task.Kind) {
		if family, found := entities.TagFamily(release.Version); !found || family != task.Family {
			return false
		}
	}
	return task.TrackMajor == "" || entities.InMajor(release.Version, task.TrackMajor)
}

func qualifiers(task *entities.Task) string {
	var words []string
	if task.TrackMajor != "" {
		words = append(words, "within major "+task.TrackMajor)
	}
	if task.HasFamily && task.Family != "" {
		words = append(words, "in the `"+task.Family+"` release line")
	}
	if len(words) == 0 {
		return ""
	}
	return " " + strings.Join(words, " ")
}

func parseTime(value string) time.Time {
	parsed, err := time.Parse(time.RFC3339, value)
	if err != nil {
		return time.Time{}
	}
	return parsed.UTC()
}
