package commands

import (
	"fmt"
	"slices"
	"strings"
	"time"

	"github.com/rios0rios0/pipelines/global/scripts/tools/dependency-updates/internal/domain/entities"
	"github.com/rios0rios0/pipelines/global/scripts/tools/dependency-updates/internal/domain/repositories"
)

// Verdicts one verification check can reach, from best to worst.
const (
	VerdictPass  = "PASS"
	VerdictWarn  = "WARN"
	VerdictFail  = "FAIL"
	VerdictError = "ERROR"
)

// Checks a changed pin goes through.
const (
	CheckAnnotations = "annotations"
	CheckBounds      = "bounds"
	CheckAdvisories  = "advisories"
	CheckCooldown    = "cooldown"
	CheckIntegrity   = "integrity"
	CheckVendored    = "vendored"
	CheckProvenance  = "provenance"
	CheckHistory     = "history"
	CheckRegistry    = "registry"
	CheckScan        = "scan"
)

// Finding is one check's verdict on one changed pin.
type Finding struct {
	Verdict string
	Check   string
	Detail  string
}

// VerifiedChange is one pin a pull request moves, and what each check found.
type VerifiedChange struct {
	Group    entities.Group
	Label    string
	From     string
	To       string
	Findings []Finding
}

// Verdict is the change's worst finding.
func (c VerifiedChange) Verdict() string {
	worst := VerdictPass
	for _, finding := range c.Findings {
		if severityOf(finding.Verdict) > severityOf(worst) {
			worst = finding.Verdict
		}
	}
	return worst
}

func severityOf(verdict string) int {
	return slices.Index([]string{VerdictPass, VerdictWarn, VerdictFail, VerdictError}, verdict)
}

// VerifyResult is what verifying a pull request found.
type VerifyResult struct {
	Changes []VerifiedChange
	// Untracked are pins on the head that nothing can check.
	Untracked []entities.Untracked
	// Vulnerable are pins on the head with known advisories, whether or not
	// the pull request touches them -- asked only when it moves at least one.
	Vulnerable []*entities.Task
	// AdvisoryError is set when the advisory database could not be consulted.
	AdvisoryError string
}

// Exit is the status a verification exits with: 2 when something could not be
// checked -- an unproven change is not a passing one -- 1 when a check failed,
// 0 otherwise.
func (r VerifyResult) Exit() int {
	worst := VerdictPass
	for _, change := range r.Changes {
		if severityOf(change.Verdict()) > severityOf(worst) {
			worst = change.Verdict()
		}
	}
	switch {
	case worst == VerdictError || r.AdvisoryError != "":
		return exitLookupFailed
	case worst == VerdictFail:
		return exitNeedsPerson
	default:
		return 0
	}
}

const (
	exitNeedsPerson  = 1
	exitLookupFailed = 2
)

// VerifyDependencies are the ports the verification reads through.
type VerifyDependencies struct {
	Base       repositories.WorkspaceRepository
	Head       repositories.WorkspaceRepository
	Releases   repositories.ReleasesRepository
	Advisories repositories.AdvisoriesRepository
	Artifacts  repositories.ArtifactsRepository
	Source     repositories.SourceRepository
	Images     repositories.ImagesRepository
	// Scanner scans a re-pinned image against the one it replaces; nil switches
	// image scanning off, which every image change then reports.
	Scanner  repositories.ImageScannerRepository
	Merger   repositories.MergeRepository
	Settings entities.Settings
	Now      time.Time
	Jobs     int
}

// VerifyPullRequestCommand proves, independently of whatever generated a pull
// request, that the pins it moves are safe to merge.
//
// It reads the DIFF between the pull request's base and head, not the
// generator's report, so it covers the scheduled pull request, a commit
// somebody pushed onto it, and a dependency bump a person wrote by hand alike.
// Each changed pin must clear every check that applies to it: no advisory the
// old version did not already have and nothing known to be malicious; a release
// past the cooldown, unless it fixes a known vulnerability; digests that match
// the release itself and its checksum manifest; an action commit that is the
// commit its tag names and descends from the one pinned before; a vendored
// file that is exactly upstream's change merged onto the base's adjustments;
// and an image digest that exists in the repository it is pinned under.
type VerifyPullRequestCommand struct {
	deps VerifyDependencies
}

// NewVerifyPullRequestCommand builds the verification.
func NewVerifyPullRequestCommand(deps VerifyDependencies) *VerifyPullRequestCommand {
	return &VerifyPullRequestCommand{deps: deps}
}

// change is one pin the diff moves, with both sides.
type change struct {
	result    VerifiedChange
	task      *entities.Task
	baseEntry *entities.ManifestEntry
	baseTask  *entities.Task
	sha       string
	reference string
}

// Execute verifies every pin the pull request moves.
func (c *VerifyPullRequestCommand) Execute() VerifyResult {
	baseManifest := entities.ParseManifest(c.deps.Base.Text(entities.ManifestPath))
	headManifest := entities.ParseManifest(c.deps.Head.Text(entities.ManifestPath))
	baseTasks, _ := BuildTasks(c.deps.Base, baseManifest, nil)
	headTasks, untracked := BuildTasks(c.deps.Head, headManifest, nil)

	changes := c.manifestChanges(baseManifest, headManifest, untracked)
	changes = append(changes, c.actionChanges(baseTasks)...)
	changes = append(changes, c.imageChanges()...)

	result := VerifyResult{Untracked: untracked}
	// A pull request that moves no pin has nothing to prove, so it asks nothing.
	// This check is required on EVERY pull request: one that consulted the
	// advisory database regardless would block them all while it is unreachable.
	if len(changes) == 0 {
		return result
	}
	advisories, err := c.lookupAdvisories(changes, headTasks)
	if err != nil {
		result.AdvisoryError = err.Error()
	}
	parallel(c.deps.Jobs, changes, func(item *change) { c.verify(item, headManifest, advisories, err == nil) })
	for _, item := range changes {
		result.Changes = append(result.Changes, item.result)
	}
	for _, task := range headTasks {
		if task.Security.Checked && len(task.Security.Current) > 0 {
			result.Vulnerable = append(result.Vulnerable, task)
		}
	}
	return result
}

func (c *VerifyPullRequestCommand) manifestChanges(
	baseManifest, headManifest []entities.ManifestEntry, untracked []entities.Untracked,
) []*change {
	var changes []*change
	for index := range headManifest {
		head := &headManifest[index]
		base := entities.FindEntry(baseManifest, head.Name)
		if base != nil && base.Current == head.Current && sameDigests(base.Digests, head.Digests) {
			continue
		}
		task := &entities.Task{
			Group: entities.GroupManifest, Label: head.Name, Kind: head.Kind, Coord: head.Coord,
			TrackMajor: head.TrackMajor, Current: head.Current, Entry: head,
		}
		if entities.IsTaggedKind(head.Kind) {
			task.Family, task.HasFamily = entities.TagFamily(head.Current)
		}
		item := &change{task: task, baseEntry: base, result: VerifiedChange{
			Group: entities.GroupManifest, Label: head.Name, To: head.Current,
		}}
		if base != nil {
			item.result.From = base.Current
			item.baseTask = &entities.Task{Group: entities.GroupManifest, Label: base.Name, Kind: base.Kind,
				Coord: base.Coord, Current: base.Current, Entry: base}
		}
		for _, row := range untracked {
			if row.Name == head.Name || strings.HasPrefix(row.Name, head.Name+"_SHA256") {
				item.result.Findings = append(item.result.Findings, Finding{
					Verdict: VerdictFail,
					Check:   CheckAnnotations,
					Detail: fmt.Sprintf(
						"`%s` has no `# %s:` annotation, so it cannot be verified",
						row.Name,
						row.Missing,
					),
				})
			}
		}
		changes = append(changes, item)
	}
	return changes
}

func sameDigests(left, right []entities.Digest) bool {
	return slices.EqualFunc(
		left,
		right,
		func(a, b entities.Digest) bool { return a.Var == b.Var && a.Value == b.Value },
	)
}

// actionChanges are the `uses:` lines of the head that the base does not have,
// one per distinct action, commit and version.
func (c *VerifyPullRequestCommand) actionChanges(baseTasks []*entities.Task) []*change {
	baseOccurrences := occurrences(c.deps.Base)
	var changes []*change
	seen := make(map[entities.ActionOccurrence]bool)
	for _, occurrence := range occurrences(c.deps.Head) {
		if seen[occurrence] || slices.Contains(baseOccurrences, occurrence) {
			continue
		}
		seen[occurrence] = true
		task := &entities.Task{
			Group: entities.GroupAction, Label: occurrence.Repository, Kind: entities.KindGitHubRelease,
			Coord: occurrence.Repository, Current: occurrence.Version, CurrentSHA: occurrence.SHA,
		}
		task.Family, task.HasFamily = entities.TagFamily(occurrence.Version)
		item := &change{task: task, sha: occurrence.SHA, result: VerifiedChange{
			Group: entities.GroupAction, Label: occurrence.Repository, To: occurrence.Version,
		}}
		if base := findTask(baseTasks, entities.GroupAction, occurrence.Repository); base != nil {
			item.baseTask = base
			item.result.From = base.Current
		}
		changes = append(changes, item)
	}
	return changes
}

func occurrences(workspace repositories.WorkspaceRepository) []entities.ActionOccurrence {
	var found []entities.ActionOccurrence
	for _, path := range workspace.YAMLFiles() {
		found = append(found, entities.ScanActionOccurrences(workspace.Text(path))...)
	}
	return found
}

func findTask(tasks []*entities.Task, group entities.Group, label string) *entities.Task {
	for _, task := range tasks {
		if task.Group == group && task.Label == label {
			return task
		}
	}
	return nil
}

// imageChanges are the digest-pinned references of the head the base lacks.
func (c *VerifyPullRequestCommand) imageChanges() []*change {
	baseImages, headImages := images(c.deps.Base), images(c.deps.Head)
	var changes []*change
	for _, reference := range sortedKeys(headImages) {
		if _, unchanged := baseImages[reference]; unchanged {
			continue
		}
		label, digest, _ := strings.Cut(reference, "@")
		item := &change{
			reference: reference,
			result:    VerifiedChange{Group: entities.GroupImage, Label: label, To: digest},
		}
		for baseReference := range baseImages {
			if baseLabel, baseDigest, _ := strings.Cut(baseReference, "@"); baseLabel == label {
				item.result.From = baseDigest
			}
		}
		changes = append(changes, item)
	}
	return changes
}

func images(workspace repositories.WorkspaceRepository) map[string]string {
	found := make(map[string]string)
	for _, path := range workspace.YAMLFiles() {
		entities.ScanImages(workspace.Text(path), false, found)
	}
	for _, path := range workspace.Dockerfiles() {
		entities.ScanImages(workspace.Text(path), true, found)
	}
	return found
}

func sortedKeys(values map[string]string) []string {
	keys := make([]string, 0, len(values))
	for key := range values {
		keys = append(keys, key)
	}
	slices.Sort(keys)
	return keys
}

// lookupAdvisories asks, in one round, about both sides of every change and
// about every pin on the head.
func (c *VerifyPullRequestCommand) lookupAdvisories(
	changes []*change, headTasks []*entities.Task,
) (map[entities.AdvisoryQuery][]entities.Advisory, error) {
	found, err := c.deps.Advisories.FindAll(append(c.changeQueries(changes), headQueries(headTasks)...))
	if err != nil {
		return nil, err
	}
	today := c.deps.Now.UTC().Format(dateLayout)
	for _, task := range headTasks {
		if task.Security.Checked {
			query := entities.AdvisoryQuery{Package: task.Security.Package, Version: task.Security.Version}
			task.Security.Current = entities.Unaccepted(
				liveAdvisories(found[query]),
				c.deps.Settings.Acceptances,
				today,
			)
		}
	}
	return found, nil
}

// changeQueries are the lookups for both sides of every change: the base's
// version only when the head's is asked about too.
func (c *VerifyPullRequestCommand) changeQueries(changes []*change) []entities.AdvisoryQuery {
	var queries []entities.AdvisoryQuery
	for _, item := range changes {
		if item.task == nil {
			continue
		}
		c.identifyChanged(item)
		for _, task := range []*entities.Task{item.task, item.baseTask} {
			if task != nil && item.task.Security.Checked && task.Security.Checked {
				queries = append(
					queries,
					entities.AdvisoryQuery{Package: task.Security.Package, Version: task.Security.Version},
				)
			}
		}
	}
	return queries
}

// headQueries are the lookups for every pin on the head. A range pin is left
// unasked: npm resolves it at run time.
func headQueries(headTasks []*entities.Task) []entities.AdvisoryQuery {
	var queries []entities.AdvisoryQuery
	for _, task := range headTasks {
		identify(task)
		if task.Security.Checked && !isRangePin(task) {
			queries = append(
				queries,
				entities.AdvisoryQuery{Package: task.Security.Package, Version: task.Security.Version},
			)
		} else {
			task.Security.Checked = false
		}
	}
	return queries
}

// identifyChanged sets which versions of a changed pin are asked about; a range
// pin is asked about the newest release in its range, which is what installs.
func (c *VerifyPullRequestCommand) identifyChanged(item *change) {
	for _, task := range []*entities.Task{item.task, item.baseTask} {
		if task == nil {
			continue
		}
		if isRangePin(task) {
			if latest, err := c.deps.Releases.Latest(task); err == nil {
				task.Latest = latest
			}
		}
		identify(task)
	}
}

func (c *VerifyPullRequestCommand) verify(
	item *change, headManifest []entities.ManifestEntry,
	advisories map[entities.AdvisoryQuery][]entities.Advisory, advisoriesKnown bool,
) {
	switch item.result.Group {
	case entities.GroupImage:
		registry := c.registryFinding(item.reference)
		item.result.Findings = append(item.result.Findings, registry)
		if registry.Verdict == VerdictPass {
			item.result.Findings = append(item.result.Findings, c.scanFinding(item))
		}
		return
	case entities.GroupAction:
		item.result.Findings = append(item.result.Findings, c.actionFindings(item)...)
	case entities.GroupManifest:
		item.result.Findings = append(item.result.Findings, c.manifestFindings(item, headManifest)...)
	}
	baseAdvisories, headAdvisories := c.sides(item, advisories)
	if advisoriesKnown {
		item.result.Findings = append(item.result.Findings, advisoryFinding(item.task, baseAdvisories, headAdvisories))
	}
	item.result.Findings = append(item.result.Findings, c.cooldownFinding(item, baseAdvisories, headAdvisories))
}

func (c *VerifyPullRequestCommand) sides(
	item *change, advisories map[entities.AdvisoryQuery][]entities.Advisory,
) ([]entities.Advisory, []entities.Advisory) {
	today := c.deps.Now.UTC().Format(dateLayout)
	lookup := func(task *entities.Task) []entities.Advisory {
		if task == nil || !task.Security.Checked {
			return nil
		}
		query := entities.AdvisoryQuery{Package: task.Security.Package, Version: task.Security.Version}
		return entities.Unaccepted(liveAdvisories(advisories[query]), c.deps.Settings.Acceptances, today)
	}
	return lookup(item.baseTask), lookup(item.task)
}

func advisoryFinding(task *entities.Task, base, head []entities.Advisory) Finding {
	if !task.Security.Checked {
		// `# osv: none` is a reviewed decision that no database covers the
		// artifact, so the check does not apply; any other gap is worth a look.
		if task.Entry != nil && task.Entry.Advisories != nil && task.Entry.Advisories.None {
			return Finding{
				Verdict: VerdictPass,
				Check:   CheckAdvisories,
				Detail:  "not applicable: " + task.Security.Note,
			}
		}
		return Finding{Verdict: VerdictWarn, Check: CheckAdvisories, Detail: "not checked: " + task.Security.Note}
	}
	if reason := entities.RejectionReason(base, head); reason != "" {
		return Finding{Verdict: VerdictFail, Check: CheckAdvisories, Detail: fmt.Sprintf("`%s` %s: %s",
			task.Security.Version, strings.ToLower(reason[:1])+reason[1:], describe(entities.Introduced(base, head)))}
	}
	fixed := entities.Resolved(base, head)
	switch {
	case len(head) > 0:
		return Finding{Verdict: VerdictWarn, Check: CheckAdvisories, Detail: fmt.Sprintf(
			"`%s` is still affected by %s, which the version it replaces had too; the scheduled run proposes the fix as "+
				"soon as one is released",
			task.Security.Version,
			describe(head),
		)}
	case len(fixed) > 0:
		return Finding{Verdict: VerdictPass, Check: CheckAdvisories, Detail: "fixes " + describe(fixed)}
	default:
		return Finding{
			Verdict: VerdictPass,
			Check:   CheckAdvisories,
			Detail:  "no known advisory affects `" + task.Security.Version + "`",
		}
	}
}

func describe(advisories []entities.Advisory) string {
	described := make([]string, 0, len(advisories))
	for _, advisory := range advisories {
		described = append(described, advisory.ID+" ("+advisory.DisplaySeverity()+")")
	}
	return strings.Join(described, ", ")
}

// cooldownFinding requires the adopted release to have been public for the
// cooldown -- unless it fixes a known vulnerability the replaced version had,
// which is the one reason to adopt a release early.
func (c *VerifyPullRequestCommand) cooldownFinding(item *change, base, head []entities.Advisory) Finding {
	task := item.task
	cooldown := cooldownFor(task, c.deps.Settings)
	if cooldown <= 0 {
		return Finding{Verdict: VerdictPass, Check: CheckCooldown, Detail: "no cooldown applies"}
	}
	if item.baseTask != nil && !entities.IsNewer(item.baseTask.Current, task.Current) {
		return Finding{Verdict: VerdictPass, Check: CheckCooldown, Detail: "not a newer release"}
	}
	releases, err := c.deps.Releases.List(task)
	if err != nil {
		return Finding{Verdict: VerdictError, Check: CheckCooldown, Detail: err.Error()}
	}
	index := slices.IndexFunc(releases, func(release entities.Release) bool {
		return entities.Normalise(release.Version) == entities.Normalise(task.Current)
	})
	policy := entities.SelectionPolicy{Now: c.deps.Now, Cooldown: cooldown}
	if index >= 0 && policy.Aged(releases[index]) {
		return Finding{Verdict: VerdictPass, Check: CheckCooldown, Detail: "published " + published(releases[index])}
	}
	if fixed := entities.Resolved(base, head); len(fixed) > 0 {
		return Finding{
			Verdict: VerdictPass,
			Check:   CheckCooldown,
			Detail:  "younger than the cooldown, waived: it fixes " + describe(fixed),
		}
	}
	if index < 0 {
		return Finding{Verdict: VerdictFail, Check: CheckCooldown, Detail: fmt.Sprintf(
			"`%s` is not among %s's published releases, so its age cannot be shown to pass the cooldown",
			task.Current,
			task.Coord,
		)}
	}
	return Finding{Verdict: VerdictFail, Check: CheckCooldown, Detail: fmt.Sprintf(
		"`%s` was published %s; nothing is adopted until it has been public for %s (eligible %s)", task.Current,
		published(releases[index]), days(cooldown), policy.EligibleOn(releases[index]).Format("2006-01-02 15:04 UTC"))}
}

func published(release entities.Release) string {
	if release.Published.IsZero() {
		return "on an unknown date"
	}
	return release.Published.UTC().Format("2006-01-02")
}

func days(duration time.Duration) string {
	return fmt.Sprintf("%d days", int(duration/entities.Day))
}

// cooldownFor is the minimum release age for one pin: its own `cooldown=`
// annotation, then an exemption by label, then the repository's setting, then
// the default. A range pin has none: npm resolves it at run time.
func cooldownFor(task *entities.Task, settings entities.Settings) time.Duration {
	switch {
	case task.Entry != nil && task.Entry.HasCooldown:
		return time.Duration(task.Entry.CooldownDays) * entities.Day
	case isRangePin(task), entities.MatchesAny(task.Label, settings.CooldownExempt):
		return 0
	case settings.HasCooldown:
		return settings.Cooldown
	default:
		return entities.DefaultCooldown
	}
}

func (c *VerifyPullRequestCommand) registryFinding(reference string) Finding {
	exists, err := c.deps.Images.Exists(reference)
	switch {
	case err != nil:
		return Finding{Verdict: VerdictError, Check: CheckRegistry, Detail: err.Error()}
	case !exists:
		return Finding{
			Verdict: VerdictFail,
			Check:   CheckRegistry,
			Detail: "the digest is not a manifest of the repository " +
				"it is pinned under; a digest is content-addressed, so this is bytes published somewhere else",
		}
	default:
		return Finding{
			Verdict: VerdictPass,
			Check:   CheckRegistry,
			Detail:  "the digest is a manifest of the repository it is pinned under",
		}
	}
}

// scanFinding compares a re-pinned image with the one it replaces: a rebuild
// that brings in a known vulnerability the old image did not have fails, as a
// package bump that did would. A NEW image has nothing to compare against, so
// what it carries is listed for the person reviewing it as a new dependency.
func (c *VerifyPullRequestCommand) scanFinding(item *change) Finding {
	if c.deps.Scanner == nil {
		return Finding{Verdict: VerdictWarn, Check: CheckScan, Detail: "not scanned: image scanning is switched off"}
	}
	if item.result.From == "" {
		return c.newImageFinding(item.reference)
	}
	evidence, err := CompareImages(c.deps.Scanner, ProposedImage(item.reference, item.result.From), item.reference)
	switch {
	case err != nil:
		return Finding{Verdict: VerdictError, Check: CheckScan, Detail: err.Error()}
	case evidence.Skipped != "":
		return Finding{Verdict: VerdictWarn, Check: CheckScan, Detail: "not scanned: " + evidence.Skipped}
	case len(evidence.Introduced) > 0:
		return Finding{Verdict: VerdictFail, Check: CheckScan, Detail: "the rebuild introduces " +
			entities.DescribeFindings(evidence.Introduced, maxListed)}
	}
	detail := fmt.Sprintf("introduces no known vulnerability; %d known in the new image", evidence.Known)
	if len(evidence.Fixed) > 0 {
		detail += fmt.Sprintf(
			", and it fixes %d: %s",
			len(evidence.Fixed),
			entities.DescribeFindings(evidence.Fixed, maxListed),
		)
	}
	return Finding{Verdict: VerdictPass, Check: CheckScan, Detail: detail}
}

func (c *VerifyPullRequestCommand) newImageFinding(reference string) Finding {
	scan, err := c.deps.Scanner.Scan(reference)
	switch {
	case err != nil:
		return Finding{Verdict: VerdictError, Check: CheckScan, Detail: err.Error()}
	case scan.Skipped != "":
		return Finding{Verdict: VerdictWarn, Check: CheckScan, Detail: "not scanned: " + scan.Skipped}
	case len(scan.Findings) == 0:
		return Finding{Verdict: VerdictPass, Check: CheckScan, Detail: "a new image with no known vulnerability"}
	}
	return Finding{Verdict: VerdictWarn, Check: CheckScan, Detail: fmt.Sprintf(
		"a new image, with nothing pinned before to compare it with: it carries %d known vulnerabilities (%s) -- "+
			"review it as a new dependency", len(scan.Findings), entities.DescribeFindings(scan.Findings, maxListed))}
}
