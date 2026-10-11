// Package commands holds the dependency-update use cases: checking pins,
// applying updates, verifying a pull request and guarding the update branch.
package commands

import (
	"fmt"
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
	return filterTasks(r.Tasks, func(task *entities.Task) bool {
		return task.Error == "" && task.Refused == "" && task.Target() != ""
	})
}

// Refused are the updates known to need a person before anything is applied:
// a Go image whose pin names a release its variant is not published for.
func (r CheckResult) Refused() []*entities.Task {
	return filterTasks(r.Tasks, func(task *entities.Task) bool { return task.Refused != "" })
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
	pins := make(map[*entities.ManifestEntry]*entities.Task)
	for _, task := range result.Tasks {
		if task.Group == entities.GroupManifest {
			pins[task.Entry] = task
		}
	}
	followers := filterTasks(result.Tasks, func(task *entities.Task) bool { return task.Follows != nil })
	parallel(c.jobs, followers, func(task *entities.Task) { c.retag(task, pins[task.Follows]) })
	return result
}

// retag moves a `golang:` image whose tag names another release than its pin
// proposes -- or holds, when it proposes none -- to the tag naming that
// release, at the digest the tag resolves to now. A tag that does not exist is
// handed to a person: a variant is not always published for every release.
func (c *CheckUpdatesCommand) retag(task, pin *entities.Task) {
	if task.Error != "" {
		return
	}
	image, _ := entities.ParseGoImage(task.Coord)
	release := task.Follows.Current
	if pin != nil && pin.Error == "" && pin.Target() != "" {
		release = pin.Proposed()
	}
	if entities.SameValue(task.Follows.Var, image.Release, release) {
		return
	}
	name := image.Name(release)
	digest, err := c.releases.Latest(&entities.Task{
		Group: entities.GroupImage, Label: name, Kind: entities.KindImage, Coord: name,
	})
	switch {
	case repositories.IsNotFound(err):
		task.Refused = fmt.Sprintf("`%s` follows `%s`, which moves to `%s`, but the registry has no `%s`: "+
			"move the image to a variant published for that release, or hold the pin", task.Label,
			task.Follows.Name, release, name)
	case err != nil:
		task.Error = err.Error()
	default:
		task.Retag, task.Latest, task.Outdated = name, digest, true
	}
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
	if task.Track != "" && !entities.InLine(latest, task.Track) {
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
			queries = append(queries, task.Security.Queries(task.Security.Version)...)
		}
	}
	found, err := c.advisories.FindAll(queries)
	if err != nil {
		return err
	}
	for _, task := range tasks {
		if task.Security.Checked {
			affecting := liveAdvisories(task.Security.Answer(found, task.Security.Version))
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
				queries = append(queries, task.Security.Queries(candidate.Version)...)
			}
		}
	}
	found, err := c.advisories.FindAll(queries)
	if err != nil {
		return err
	}
	for task, listed := range candidates {
		for index := range listed {
			listed[index].Advisories = entities.Unaccepted(
				liveAdvisories(task.Security.Answer(found, listed[index].Version)), c.settings.Acceptances, today)
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
	if task.Track != "" && !entities.InLine(version, task.Track) {
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
	packages, note, known := advisoryPackages(task)
	task.Security = entities.SecurityStatus{Packages: packages, Checked: known, Note: note, Version: task.Current}
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

func advisoryPackages(task *entities.Task) ([]entities.Package, string, bool) {
	switch task.Group {
	case entities.GroupAction:
		return []entities.Package{{Ecosystem: entities.EcosystemGitHubActions, Name: task.Coord}}, "", true
	case entities.GroupImage:
		return nil, "container images are verified by digest; their packages are not resolved here", false
	case entities.GroupManifest:
	}
	if source := task.Entry.Advisories; source != nil {
		switch {
		case source.None:
			return nil, "`# osv: none`: no advisory database covers this artifact", false
		case len(source.Packages) == 0:
			return nil, "`# osv: " + source.Ecosystem + "` names no package to look up", false
		}
		packages := make([]entities.Package, 0, len(source.Packages))
		for _, name := range source.Packages {
			packages = append(packages, entities.Package{Ecosystem: source.Ecosystem, Name: name})
		}
		return packages, "", true
	}
	if ecosystem, implied := impliedEcosystems()[task.Kind]; implied {
		return []entities.Package{{Ecosystem: ecosystem, Name: task.Coord}}, "", true
	}
	return nil, "no `# osv:` annotation", false
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
