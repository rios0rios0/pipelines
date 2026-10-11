// Package commands holds the dependency-update use cases: checking pins,
// applying updates, verifying a pull request and guarding the update branch.
package commands

import (
	"slices"
	"sync"
	"time"

	"github.com/rios0rios0/pipelines/global/scripts/tools/dependency-updates/internal/domain/entities"
	"github.com/rios0rios0/pipelines/global/scripts/tools/dependency-updates/internal/domain/repositories"
)

// maxCandidates bounds how many releases of one pin are weighed: enough to step
// past a bad release or two, never a pin's whole history.
const maxCandidates = 10

// dateLayout is the calendar date an acceptance expires on.
const dateLayout = "2006-01-02"

// CheckResult is everything one check found.
type CheckResult struct {
	Manifest  []entities.ManifestEntry
	Tasks     []*entities.Task
	Untracked []entities.Untracked
	Drift     []entities.Drift
	// AdvisoryError is set when the advisory database could not be consulted,
	// which proves nothing about what is safe and fails the run.
	AdvisoryError string
}

// Outdated are the tasks with a newer release upstream.
func (r CheckResult) Outdated() []*entities.Task {
	return filterTasks(r.Tasks, func(task *entities.Task) bool { return task.Outdated })
}

// Failed are the tasks whose upstream could not be consulted.
func (r CheckResult) Failed() []*entities.Task {
	return filterTasks(r.Tasks, func(task *entities.Task) bool { return task.Error != "" })
}

// Proposals are the tasks the policy chose a release for.
func (r CheckResult) Proposals() []*entities.Task {
	return filterTasks(r.Tasks, func(task *entities.Task) bool { return task.Error == "" && task.Target() != "" })
}

// Vulnerable are the tasks whose pin in use today has unaccepted advisories.
func (r CheckResult) Vulnerable() []*entities.Task {
	return filterTasks(r.Tasks, (*entities.Task).IsVulnerable)
}

// Held are the tasks with a release the cooldown kept back.
func (r CheckResult) Held() []*entities.Task {
	return filterTasks(r.Tasks, func(task *entities.Task) bool { return task.Selection.Held != nil })
}

func filterTasks(tasks []*entities.Task, keep func(*entities.Task) bool) []*entities.Task {
	var kept []*entities.Task
	for _, task := range tasks {
		if keep(task) {
			kept = append(kept, task)
		}
	}
	return kept
}

// CheckUpdatesCommand reads the pins out of the repository, asks each upstream
// what is current, asks the advisory databases what is known about the pins in
// use and about every release they could move to, and chooses what to propose.
type CheckUpdatesCommand struct {
	workspace  repositories.WorkspaceRepository
	releases   repositories.ReleasesRepository
	advisories repositories.AdvisoriesRepository
	settings   entities.Settings
	now        time.Time
	jobs       int
}

// NewCheckUpdatesCommand builds the check.
func NewCheckUpdatesCommand(
	workspace repositories.WorkspaceRepository,
	releases repositories.ReleasesRepository,
	advisories repositories.AdvisoriesRepository,
	settings entities.Settings,
	now time.Time,
	jobs int,
) *CheckUpdatesCommand {
	return &CheckUpdatesCommand{
		workspace: workspace, releases: releases, advisories: advisories,
		settings: settings, now: now, jobs: jobs,
	}
}

// Discover reads the pins out of the workspace without asking anything
// upstream, so the caller can say how much is about to be checked.
func (c *CheckUpdatesCommand) Discover() CheckResult {
	manifest := entities.ParseManifest(c.workspace.Text(entities.ManifestPath))
	tasks, untracked := BuildTasks(c.workspace, manifest, c.settings.Ignore)
	return CheckResult{Manifest: manifest, Tasks: tasks, Untracked: untracked, Drift: FindDrift(c.workspace, manifest)}
}

// Execute asks every upstream and advisory database about the discovered pins,
// and lets the policy choose what to propose.
func (c *CheckUpdatesCommand) Execute(result CheckResult) CheckResult {
	if len(result.Tasks) == 0 {
		return result
	}
	parallel(c.jobs, result.Tasks, func(task *entities.Task) { c.resolve(task, result.Manifest) })
	if err := c.assess(result.Tasks); err != nil {
		result.AdvisoryError = err.Error()
	}
	return result
}

func (c *CheckUpdatesCommand) resolve(task *entities.Task, manifest []entities.ManifestEntry) {
	latest, err := c.releases.Latest(task)
	if err == nil {
		latest, err = c.withinBounds(task, latest, manifest)
	}
	if err != nil {
		task.Error = err.Error()
		return
	}
	task.Latest = latest
	if task.Group == entities.GroupImage {
		task.Outdated = latest != task.Current
	} else {
		task.Outdated = entities.IsNewer(task.Current, latest)
	}
}

// withinBounds is `latest`, or the newest release the pin may follow when
// `latest` lies outside it.
//
// A pin held inside a major reports nothing when upstream's newest release is
// OUTSIDE it -- GoReleaser 1.x to 2.x is a migration, not an update, and
// reporting it every run is how a check gets muted. A release from ANOTHER line
// of the same repository is never an update either (see TagFamily). And a pin
// with a ceiling never moves past the pin it names: the golden golangci-lint
// configuration must not name a linter the pinned binary does not have.
func (c *CheckUpdatesCommand) withinBounds(
	task *entities.Task, latest string, manifest []entities.ManifestEntry,
) (string, error) {
	if task.Group == entities.GroupImage {
		return latest, nil
	}
	if task.TrackMajor != "" && !entities.InMajor(latest, task.TrackMajor) {
		return task.Current, nil
	}
	if task.HasFamily && entities.IsTaggedKind(task.Kind) {
		if family, found := entities.TagFamily(latest); !found || family != task.Family {
			return task.Current, nil
		}
	}
	ceiling := ceilingOf(task, manifest)
	if ceiling == "" || !entities.IsNewer(ceiling, latest) {
		return latest, nil
	}
	releases, err := c.releases.List(task)
	if err != nil {
		return "", err
	}
	best := task.Current
	for _, release := range releases {
		if isFinal(release) && !entities.IsNewer(ceiling, release.Version) && entities.IsNewer(best, release.Version) {
			best = release.Version
		}
	}
	return best, nil
}

func ceilingOf(task *entities.Task, manifest []entities.ManifestEntry) string {
	if task.Entry == nil || task.Entry.Ceiling == "" {
		return ""
	}
	if bound := entities.FindEntry(manifest, task.Entry.Ceiling); bound != nil {
		return bound.Current
	}
	return ""
}

func isFinal(release entities.Release) bool {
	return !release.Prerelease && !entities.IsPrerelease(release.Version)
}

// assess asks the advisory databases about the pins in use today, then about
// every release each pin could move to, and lets the policy choose.
func (c *CheckUpdatesCommand) assess(tasks []*entities.Task) error {
	today := c.now.UTC().Format(dateLayout)
	var queries []entities.AdvisoryQuery
	for _, task := range tasks {
		if task.Error != "" {
			continue
		}
		identify(task)
		if task.Security.Checked {
			queries = append(
				queries,
				entities.AdvisoryQuery{Package: task.Security.Package, Version: task.Security.Version},
			)
		}
	}
	found, err := c.advisories.FindAll(queries)
	if err != nil {
		return err
	}
	for _, task := range tasks {
		if task.Security.Checked {
			query := entities.AdvisoryQuery{Package: task.Security.Package, Version: task.Security.Version}
			affecting := liveAdvisories(found[query])
			task.Security.Current = entities.Unaccepted(affecting, c.settings.Acceptances, today)
			task.Security.Accepted = entities.Introduced(task.Security.Current, affecting)
		}
	}
	return c.choose(tasks, today)
}

func liveAdvisories(advisories []entities.Advisory) []entities.Advisory {
	return slices.DeleteFunc(
		slices.Clone(advisories),
		func(advisory entities.Advisory) bool { return advisory.Withdrawn },
	)
}

// choose weighs every candidate release of every pin that is stale or
// vulnerable.
func (c *CheckUpdatesCommand) choose(tasks []*entities.Task, today string) error {
	candidates := make(map[*entities.Task][]entities.Candidate)
	var queries []entities.AdvisoryQuery
	for _, task := range tasks {
		if task.Error != "" || task.Group == entities.GroupImage || (!task.Outdated && !task.IsVulnerable()) {
			continue
		}
		listed, err := c.candidates(task)
		if err != nil {
			task.Error = err.Error()
			continue
		}
		candidates[task] = listed
		if task.Security.Checked {
			for _, candidate := range listed {
				queries = append(
					queries,
					entities.AdvisoryQuery{Package: task.Security.Package, Version: candidate.Version},
				)
			}
		}
	}
	found, err := c.advisories.FindAll(queries)
	if err != nil {
		return err
	}
	for task, listed := range candidates {
		for index := range listed {
			query := entities.AdvisoryQuery{Package: task.Security.Package, Version: listed[index].Version}
			listed[index].Advisories = entities.Unaccepted(liveAdvisories(found[query]), c.settings.Acceptances, today)
		}
		policy := entities.SelectionPolicy{Now: c.now, Cooldown: cooldownFor(task, c.settings)}
		task.Selection = policy.Select(task.Security.Current, listed)
	}
	return nil
}

// candidates are the releases a pin could move to, newest first: final
// releases newer than the pin, no newer than the bounded latest, in the pin's
// release line.
func (c *CheckUpdatesCommand) candidates(task *entities.Task) ([]entities.Candidate, error) {
	if !task.Outdated {
		return nil, nil
	}
	if isRangePin(task) {
		// npm resolves the newest release in the range at run time; the pin
		// only ever moves the range, so the newest release is the candidate.
		return []entities.Candidate{{Release: entities.Release{Version: task.Latest}}}, nil
	}
	releases, err := c.releases.List(task)
	if err != nil {
		return nil, err
	}
	if !slices.ContainsFunc(releases, func(release entities.Release) bool {
		return entities.Normalise(release.Version) == entities.Normalise(task.Latest)
	}) {
		releases = append(releases, entities.Release{Version: task.Latest})
	}
	entities.NewestFirst(releases)
	var listed []entities.Candidate
	for _, release := range releases {
		if !isFinal(release) || !entities.IsNewer(task.Current, release.Version) ||
			entities.IsNewer(task.Latest, release.Version) || !sameLine(task, release.Version) {
			continue
		}
		listed = append(listed, entities.Candidate{Release: release})
		if len(listed) == maxCandidates {
			break
		}
	}
	return listed, nil
}

func sameLine(task *entities.Task, version string) bool {
	if task.TrackMajor != "" && !entities.InMajor(version, task.TrackMajor) {
		return false
	}
	if task.HasFamily && entities.IsTaggedKind(task.Kind) {
		family, found := entities.TagFamily(version)
		return found && family == task.Family
	}
	return true
}

func isRangePin(task *entities.Task) bool {
	return task.Group == entities.GroupManifest && entities.IsMajorOnly(task.Current)
}

// identify sets where a pin's advisories are looked up and which version is
// asked about.
func identify(task *entities.Task) {
	pkg, note, known := advisoryPackage(task)
	task.Security = entities.SecurityStatus{Package: pkg, Checked: known, Note: note, Version: task.Current}
	if !known || !isRangePin(task) {
		return
	}
	// A range pin runs the newest release in its range. That is the latest
	// release when it is still in the pin's major; otherwise the registry
	// publishes no per-major answer cheaply, and saying so beats guessing.
	if entities.IsNewer(task.Current, task.Latest) || task.Latest == "" {
		task.Security.Checked = false
		task.Security.Note = "range pin: npm resolves the newest " + task.Current +
			".x at run time, and no registry answer names it without the full package history"
		return
	}
	task.Security.Version = task.Latest
}

func advisoryPackage(task *entities.Task) (entities.Package, string, bool) {
	switch task.Group {
	case entities.GroupAction:
		return entities.Package{Ecosystem: entities.EcosystemGitHubActions, Name: task.Coord}, "", true
	case entities.GroupImage:
		return entities.Package{}, "container images are verified by digest; their packages are not resolved here", false
	case entities.GroupManifest:
	}
	if source := task.Entry.Advisories; source != nil {
		if source.None {
			return entities.Package{}, "`# osv: none`: no advisory database covers this artifact", false
		}
		return entities.Package{Ecosystem: source.Ecosystem, Name: source.Package}, "", true
	}
	if ecosystem, implied := impliedEcosystems()[task.Kind]; implied {
		return entities.Package{Ecosystem: ecosystem, Name: task.Coord}, "", true
	}
	return entities.Package{}, "no `# osv:` annotation", false
}

// impliedEcosystems are the upstream kinds whose coordinate IS a package name
// in an advisory database, so they need no `# osv:` annotation.
func impliedEcosystems() map[string]string {
	return map[string]string{
		entities.KindPyPI:     entities.EcosystemPyPI,
		entities.KindNpm:      entities.EcosystemNpm,
		entities.KindRubyGems: entities.EcosystemRubyGems,
		entities.KindGoProxy:  entities.EcosystemGo,
	}
}

func parallel[T any](jobs int, items []T, work func(T)) {
	semaphore := make(chan struct{}, max(1, jobs))
	var group sync.WaitGroup
	for _, item := range items {
		group.Go(func() {
			semaphore <- struct{}{}
			defer func() { <-semaphore }()
			work(item)
		})
	}
	group.Wait()
}
