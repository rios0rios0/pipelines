// Package doubles holds handwritten test doubles for the dependency-update
// ports: in-memory repositories and stubs with canned answers. No mocking
// library: each double implements a port the way a test needs it to behave.
package doubles

import (
	"maps"
	"slices"
	"strings"
	"time"

	"github.com/rios0rios0/pipelines/global/scripts/tools/dependency-updates/internal/domain/entities"
	"github.com/rios0rios0/pipelines/global/scripts/tools/dependency-updates/internal/domain/repositories"
)

// InMemoryWorkspace is a repository held in a map of path to contents.
type InMemoryWorkspace struct {
	Files   map[string]string
	written map[string]string
}

// NewInMemoryWorkspace builds a workspace from `files`.
func NewInMemoryWorkspace(files map[string]string) *InMemoryWorkspace {
	return &InMemoryWorkspace{Files: maps.Clone(files), written: maps.Clone(files)}
}

// Root is a fixed name.
func (w *InMemoryWorkspace) Root() string { return "/workspace" }

// Text is a file's contents, empty when absent.
func (w *InMemoryWorkspace) Text(path string) string { return w.Files[path] }

// Set replaces a file's contents.
func (w *InMemoryWorkspace) Set(path, text string) bool {
	w.Files[path] = text
	return true
}

// YAMLFiles are the files ending in .yaml or .yml, by name.
func (w *InMemoryWorkspace) YAMLFiles() []string {
	return w.matching(
		func(path string) bool { return strings.HasSuffix(path, ".yaml") || strings.HasSuffix(path, ".yml") },
	)
}

// Dockerfiles are the files whose name starts with Dockerfile, by name.
func (w *InMemoryWorkspace) Dockerfiles() []string {
	return w.matching(
		func(path string) bool { return strings.HasPrefix(path[strings.LastIndex(path, "/")+1:], "Dockerfile") },
	)
}

func (w *InMemoryWorkspace) matching(keep func(string) bool) []string {
	var paths []string
	for _, path := range slices.Sorted(maps.Keys(w.Files)) {
		if keep(path) {
			paths = append(paths, path)
		}
	}
	return paths
}

// IsFile is true for a path that holds contents.
func (w *InMemoryWorkspace) IsFile(path string) bool {
	_, found := w.Files[path]
	return found
}

// IsDir is true when some file lives under `path`.
func (w *InMemoryWorkspace) IsDir(path string) bool {
	return slices.ContainsFunc(slices.Collect(maps.Keys(w.Files)), func(file string) bool {
		return strings.HasPrefix(file, path+"/")
	})
}

// Changed lists the files that differ from the last write.
func (w *InMemoryWorkspace) Changed() []string {
	var changed []string
	for _, path := range slices.Sorted(maps.Keys(w.Files)) {
		if previous, found := w.written[path]; !found || previous != w.Files[path] {
			changed = append(changed, path)
		}
	}
	return changed
}

// Write records the current contents as written.
func (w *InMemoryWorkspace) Write() ([]string, error) {
	changed := w.Changed()
	w.written = maps.Clone(w.Files)
	return changed, nil
}

// StubReleases answers with canned releases, by coordinate.
type StubReleases struct {
	Latests map[string]string
	Lists   map[string][]entities.Release
	Errors  map[string]error
}

// Latest is the canned newest release.
func (s *StubReleases) Latest(task *entities.Task) (string, error) {
	if err := s.Errors[task.Coord]; err != nil {
		return "", err
	}
	latest, found := s.Latests[task.Coord]
	if !found {
		return "", repositories.NewLookupError("no stub latest for %s", task.Coord)
	}
	return latest, nil
}

// List is the canned release list.
func (s *StubReleases) List(task *entities.Task) ([]entities.Release, error) {
	if err := s.Errors[task.Coord]; err != nil {
		return nil, err
	}
	return slices.Clone(s.Lists[task.Coord]), nil
}

// StubAdvisories evaluates canned advisories with the domain's own ranges, the
// way the offline fixture does.
type StubAdvisories struct {
	Advisories []entities.Advisory
	Err        error
}

// FindAll answers each query with the advisories affecting it.
func (s *StubAdvisories) FindAll(
	queries []entities.AdvisoryQuery,
) (map[entities.AdvisoryQuery][]entities.Advisory, error) {
	if s.Err != nil {
		return nil, s.Err
	}
	found := make(map[entities.AdvisoryQuery][]entities.Advisory, len(queries))
	for _, query := range queries {
		for _, advisory := range s.Advisories {
			if advisory.Affects(query.Package, query.Version) {
				found[query] = append(found[query], advisory)
			}
		}
	}
	return found, nil
}

// StubArtifacts answers with canned digests, documents and file contents, by
// URL; anything it does not know is a 404.
type StubArtifacts struct {
	Digests  map[string]string
	Texts    map[string]string
	Contents map[string]string
}

// AssetDigest is the canned digest.
func (s *StubArtifacts) AssetDigest(url string) (string, string, error) {
	digest, found := s.Digests[url]
	if !found {
		return "", "", repositories.NewNotFoundError("%s -> HTTP 404", url)
	}
	return digest, "GitHub's recorded digest of the release asset", nil
}

// Text is the canned document.
func (s *StubArtifacts) Text(url string) (string, error) {
	text, found := s.Texts[url]
	if !found {
		return "", repositories.NewNotFoundError("%s -> HTTP 404", url)
	}
	return text, nil
}

// Content is the canned file.
func (s *StubArtifacts) Content(url string) ([]byte, error) {
	content, found := s.Contents[url]
	if !found {
		return nil, repositories.NewNotFoundError("%s -> HTTP 404", url)
	}
	return []byte(content), nil
}

// StubSource answers with canned tag commits (`repo@tag`) and comparisons
// (`repo base...head`).
type StubSource struct {
	Commits     map[string]string
	Comparisons map[string]entities.Comparison
}

// TagCommit is the canned commit.
func (s *StubSource) TagCommit(repository, tag string) (string, error) {
	sha, found := s.Commits[repository+"@"+tag]
	if !found {
		return "", repositories.NewNotFoundError("%s@%s -> HTTP 404", repository, tag)
	}
	return sha, nil
}

// Compare is the canned comparison.
func (s *StubSource) Compare(repository, base, head string) (entities.Comparison, error) {
	comparison, found := s.Comparisons[repository+" "+base+"..."+head]
	if !found {
		return entities.Comparison{}, repositories.NewNotFoundError("%s %s...%s -> HTTP 404", repository, base, head)
	}
	return comparison, nil
}

// StubImages answers whether a reference exists.
type StubImages struct {
	Existing []string
}

// Exists is true for a listed reference.
func (s *StubImages) Exists(reference string) (bool, error) {
	return slices.Contains(s.Existing, reference), nil
}

// StubMerger answers every merge with a canned result.
type StubMerger struct {
	Merged    string
	Conflicts int
	Err       error
	Calls     [][3]string
}

// Merge records the call and returns the canned result.
func (s *StubMerger) Merge(ours, base, theirs string) (string, int, error) {
	s.Calls = append(s.Calls, [3]string{ours, base, theirs})
	return s.Merged, s.Conflicts, s.Err
}

// StubHistory answers with a canned HEAD time.
type StubHistory struct {
	Head time.Time
	Err  error
}

// HeadCommitTime is the canned time.
func (s *StubHistory) HeadCommitTime() (time.Time, error) { return s.Head, s.Err }

// StubPullRequests answers with canned pull requests and branch commits.
type StubPullRequests struct {
	Closed      []entities.PullRequest
	Commits     []entities.Commit
	CommitsErr  error
	ClosedErr   error
	MissingHead bool
}

// ClosedPullRequests are the canned pull requests.
func (s *StubPullRequests) ClosedPullRequests(string, string) ([]entities.PullRequest, error) {
	return s.Closed, s.ClosedErr
}

// BranchCommits are the canned commits; a NotFound when the branch is missing.
func (s *StubPullRequests) BranchCommits(string, string, string) ([]entities.Commit, error) {
	if s.MissingHead {
		return nil, repositories.NewNotFoundError("compare -> HTTP 404")
	}
	return s.Commits, s.CommitsErr
}

// StubImageScanner answers with canned scans, by reference; a reference it does
// not know is a failed scan.
type StubImageScanner struct {
	Scans map[string]entities.ImageScan
}

// Scan is the canned scan.
func (s *StubImageScanner) Scan(reference string) (entities.ImageScan, error) {
	scan, found := s.Scans[reference]
	if !found {
		return entities.ImageScan{}, repositories.NewLookupError("no stub scan for %s", reference)
	}
	return scan, nil
}
