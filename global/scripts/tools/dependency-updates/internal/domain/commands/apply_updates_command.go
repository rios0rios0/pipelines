package commands

import (
	"errors"
	"fmt"
	"maps"
	"strings"

	"github.com/rios0rios0/pipelines/global/scripts/tools/dependency-updates/internal/domain/entities"
	"github.com/rios0rios0/pipelines/global/scripts/tools/dependency-updates/internal/domain/repositories"
)

// ApplyResult is what applying the proposals did.
type ApplyResult struct {
	Applied []*entities.Task
	Refused []*entities.Task
	Fixes   []entities.CopyChange
}

// ApplyUpdatesCommand rewrites every proposed pin in the workspace.
//
// A new digest is never guessed and an old one is never carried forward. It is
// the SHA-256 GitHub recorded for the release asset -- or the SHA-256 of the
// downloaded bytes, for a release published before GitHub recorded any -- it
// must match the publisher's checksum manifest when the pin names one, and the
// `# asset:` template that located it must first reproduce the committed digest
// for the CURRENT version. That last check is what proves the template names
// the file the installer really verifies. A pin that fails any of them is left
// exactly as it is and handed to a person; nothing is ever written half-updated.
type ApplyUpdatesCommand struct {
	workspace repositories.WorkspaceRepository
	artifacts repositories.ArtifactsRepository
	source    repositories.SourceRepository
	merger    repositories.MergeRepository
	// scanner scans an image rebuild before it is proposed; nil skips it.
	scanner repositories.ImageScannerRepository
	jobs    int
}

// NewApplyUpdatesCommand builds the apply step.
func NewApplyUpdatesCommand(
	workspace repositories.WorkspaceRepository,
	artifacts repositories.ArtifactsRepository,
	source repositories.SourceRepository,
	merger repositories.MergeRepository,
	scanner repositories.ImageScannerRepository,
	jobs int,
) *ApplyUpdatesCommand {
	return &ApplyUpdatesCommand{
		workspace: workspace, artifacts: artifacts, source: source, merger: merger, scanner: scanner, jobs: jobs,
	}
}

// Execute prepares every proposal against upstream, in parallel and before any
// file is touched, then writes the ones that prepared cleanly.
func (c *ApplyUpdatesCommand) Execute(check CheckResult) ApplyResult {
	// What the check already refused, read before preparing sets any more.
	result := ApplyResult{Refused: check.Refused()}
	proposals := check.Proposals()
	parallel(c.jobs, proposals, c.prepare)

	before := entities.ManifestValues(check.Manifest)
	targets := maps.Clone(before)
	for _, task := range proposals {
		if task.Apply == nil || task.Refused != "" || task.Error != "" {
			if task.Refused != "" {
				result.Refused = append(result.Refused, task)
			}
			continue
		}
		if err := followsWrittenPin(task, targets); err != nil {
			task.Refused = err.Error()
			result.Refused = append(result.Refused, task)
			continue
		}
		if err := c.write(task, targets); err != nil {
			task.Refused = err.Error()
			result.Refused = append(result.Refused, task)
			continue
		}
		if task.Rewritten == 0 {
			task.Refused = "no line in the repository matched it, so there was nothing to rewrite"
			result.Refused = append(result.Refused, task)
			continue
		}
		task.Applied = true
		result.Applied = append(result.Applied, task)
	}
	result.Fixes = c.alignCopies(check.Manifest, targets, before)
	return result
}

// followsWrittenPin refuses to move a `golang:` image to a release its pin is
// not moving to. The images are written after the pins, so a pin whose own
// update was refused keeps its images where they are.
func followsWrittenPin(task *entities.Task, targets map[string]string) error {
	if task.Retag == "" {
		return nil
	}
	image, _ := entities.ParseGoImage(task.Retag)
	if want := targets[task.Follows.Var]; !entities.SameValue(task.Follows.Var, image.Release, want) {
		return entities.Refuse("`%s` follows `%s`, which this run leaves at `%s`, so it stays where it is",
			task.Label, task.Follows.Name, want)
	}
	return nil
}

func (c *ApplyUpdatesCommand) prepare(task *entities.Task) {
	var (
		plan *entities.Plan
		err  error
	)
	switch task.Group {
	case entities.GroupManifest:
		plan, err = c.prepareManifest(task)
	case entities.GroupAction:
		plan, err = c.prepareAction(task)
	case entities.GroupImage:
		plan, err = c.prepareImage(task)
	}
	var refused *entities.RefusedError
	switch {
	case err == nil:
		task.Apply = plan
	case errors.As(err, &refused), repositories.IsNotFound(err):
		task.Refused = err.Error()
	default:
		task.Error = err.Error()
	}
}

func (c *ApplyUpdatesCommand) prepareManifest(task *entities.Task) (*entities.Plan, error) {
	entry := task.Entry
	proposed := task.Proposed()
	if !entities.SafeVersion.MatchString(proposed) {
		return nil, entities.Refuse(
			"upstream named the release %q, which is not safe to write into a sourced shell file",
			task.Target(),
		)
	}
	if err := requireAnnotations(entry, proposed); err != nil {
		return nil, err
	}
	if entry.Vendored != "" {
		return c.prepareVendored(task, proposed)
	}
	digests := make([]entities.DigestPlan, 0, len(entry.Digests))
	for _, digest := range entry.Digests {
		derived, err := c.deriveDigest(digest, task.Current, proposed)
		if err != nil {
			return nil, err
		}
		digests = append(digests, derived)
	}
	if entry.Checksums != "" && len(digests) > 0 {
		if err := c.crossCheck(entities.Render(entry.Checksums, proposed), proposed, digests); err != nil {
			return nil, err
		}
	}
	return &entities.Plan{New: proposed, Digests: digests}, nil
}

func requireAnnotations(entry *entities.ManifestEntry, proposed string) error {
	var missing []string
	for _, digest := range entry.Digests {
		if digest.Asset == "" {
			missing = append(missing, digest.Var)
		}
	}
	switch len(missing) {
	case 0:
		return nil
	case 1:
		return entities.Refuse(
			"%s has no `# asset:` annotation, so its digest cannot be re-derived for %s",
			missing[0],
			proposed,
		)
	default:
		return entities.Refuse("%s have no `# asset:` annotation, so their digests cannot be re-derived for %s",
			strings.Join(missing, ", "), proposed)
	}
}

// deriveDigest is the SHA-256 of one digest's asset at `proposed` -- once its
// template has proven itself at `current`.
func (c *ApplyUpdatesCommand) deriveDigest(
	digest entities.Digest,
	current, proposed string,
) (entities.DigestPlan, error) {
	today, next := entities.Render(digest.Asset, current), entities.Render(digest.Asset, proposed)
	if today == next {
		return entities.DigestPlan{}, entities.Refuse(
			"the `# asset:` template for %s has no `{version}`, so it cannot locate %s", digest.Var, proposed)
	}
	reproduced, _, err := c.artifacts.AssetDigest(today)
	if repositories.IsNotFound(err) {
		return entities.DigestPlan{}, entities.Refuse(
			"the `# asset:` template for %s does not locate the pinned %s (%s); fix the template",
			digest.Var,
			current,
			err,
		)
	}
	if err != nil {
		return entities.DigestPlan{}, err
	}
	if reproduced != digest.Value {
		return entities.DigestPlan{}, entities.Refuse(
			"the `# asset:` template for %s locates a file whose SHA-256 is not "+
				"the committed one for %s, so it is not the asset the installer verifies and cannot be trusted for %s",
			digest.Var,
			current,
			proposed,
		)
	}
	value, source, err := c.artifacts.AssetDigest(next)
	if repositories.IsNotFound(err) {
		return entities.DigestPlan{}, entities.Refuse(
			"%s; if the release renamed its assets, the installer and the `# asset:` template both have to follow", err)
	}
	if err != nil {
		return entities.DigestPlan{}, err
	}
	return entities.DigestPlan{Var: digest.Var, Old: digest.Value, New: value, Source: source, URL: next}, nil
}

// crossCheck requires every new digest to be the one the publisher's checksum
// manifest lists for its asset.
func (c *ApplyUpdatesCommand) crossCheck(url, proposed string, digests []entities.DigestPlan) error {
	text, err := c.artifacts.Text(url)
	if repositories.IsNotFound(err) {
		return entities.Refuse("the checksum manifest %s does not exist for %s", url, proposed)
	}
	if err != nil {
		return err
	}
	for index := range digests {
		asset := entities.AssetName(digests[index].URL)
		published := entities.PublishedChecksum(text, asset)
		if published == "" {
			return entities.Refuse("%s publishes no SHA-256 for %s", url, asset)
		}
		if published != digests[index].New {
			return entities.Refuse(
				"%s publishes %s for %s, but the asset itself is %s. A release that disagrees with its "+
					"own checksums is what verification exists to catch; look before trusting either",
				url,
				published,
				asset,
				digests[index].New,
			)
		}
		digests[index].Source += fmt.Sprintf(", matching `%s`", entities.AssetName(url))
	}
	return nil
}

// prepareVendored re-applies this repository's adjustments to a vendored file
// on top of the new upstream release: a three-way merge from the upstream file
// the copy was taken from (whose SHA-256 is committed, so the base itself is
// verified), to the new release.
func (c *ApplyUpdatesCommand) prepareVendored(task *entities.Task, proposed string) (*entities.Plan, error) {
	entry := task.Entry
	if len(entry.Digests) != 1 {
		return nil, entities.Refuse("%s is vendored, so it must carry exactly one digest -- the upstream file %s was "+
			"copied from -- and it carries %d", entry.Name, entry.Vendored, len(entry.Digests))
	}
	digest := entry.Digests[0]
	base, theirs, next, err := c.vendoredSides(digest, task.Current, proposed)
	if err != nil {
		return nil, err
	}
	if entities.DeclaresPlugin(string(theirs)) && !entities.DeclaresPlugin(string(base)) {
		return nil, entities.Refuse(
			"%s %s declares a custom linter plugin: code that would run in every consumer's lint "+
				"job, which is a decision for a person, not an update",
			entry.Coord,
			proposed,
		)
	}
	if !c.workspace.IsFile(entry.Vendored) {
		return nil, entities.Refuse("the vendored file %s does not exist", entry.Vendored)
	}
	merged, conflicts, err := c.merger.Merge(c.workspace.Text(entry.Vendored), string(base), string(theirs))
	if err != nil {
		return nil, entities.Refuse("could not merge %s onto %s: %s", entry.Vendored, proposed, err)
	}
	if conflicts > 0 {
		return nil, entities.Refuse(
			"the upstream change to %s conflicts with this repository's adjustments in %d place(s); "+
				"merge it by hand",
			entry.Vendored,
			conflicts,
		)
	}
	enabled, disabled := entities.LinterChanges(string(base), string(theirs))
	tagPrefix := strings.TrimSuffix(task.Target(), entities.Normalise(task.Target()))
	return &entities.Plan{
		New: proposed,
		Digests: []entities.DigestPlan{{
			Var: digest.Var, Old: digest.Value, New: entities.SHA256Hex(theirs), URL: next,
			Source: "SHA-256 of the upstream file, merged onto this repository's adjustments",
		}},
		Vendored: &entities.VendoredPlan{
			Path: entry.Vendored, Merged: merged, Enabled: enabled, Disabled: disabled,
			CompareURL: fmt.Sprintf("https://github.com/%s/compare/%s%s...%s",
				entry.Coord, tagPrefix, entities.Normalise(task.Current), task.Target()),
		},
	}, nil
}

func (c *ApplyUpdatesCommand) vendoredSides(
	digest entities.Digest,
	current, proposed string,
) ([]byte, []byte, string, error) {
	today, next := entities.Render(digest.Asset, current), entities.Render(digest.Asset, proposed)
	if today == next {
		return nil, nil, "", entities.Refuse(
			"the `# asset:` template for %s has no `{version}`, so it cannot locate %s", digest.Var, proposed)
	}
	base, err := c.artifacts.Content(today)
	if repositories.IsNotFound(err) {
		return nil, nil, "", entities.Refuse(
			"the `# asset:` template for %s does not locate the pinned %s (%s); fix the template",
			digest.Var,
			current,
			err,
		)
	}
	if err != nil {
		return nil, nil, "", err
	}
	if entities.SHA256Hex(base) != digest.Value {
		return nil, nil, "", entities.Refuse("the `# asset:` template for %s locates a file whose SHA-256 is not the "+
			"committed one for %s, so it is not the file this repository's copy was taken from, and cannot be "+
			"merged from", digest.Var, current)
	}
	theirs, err := c.artifacts.Content(next)
	if repositories.IsNotFound(err) {
		return nil, nil, "", entities.Refuse(
			"%s; if the release moved the file, the `# asset:` template has to follow",
			err,
		)
	}
	if err != nil {
		return nil, nil, "", err
	}
	return base, theirs, next, nil
}

func (c *ApplyUpdatesCommand) prepareAction(task *entities.Task) (*entities.Plan, error) {
	tag := task.Target()
	if !entities.SafeTag.MatchString(tag) {
		return nil, entities.Refuse("upstream named the release %q, which is not safe to write into a workflow", tag)
	}
	sha, err := c.source.TagCommit(task.Coord, tag)
	if err != nil {
		return nil, err
	}
	plan := &entities.Plan{New: tag, SHA: sha}
	if task.CurrentSHA == "" || task.CurrentSHA == sha {
		return plan, nil
	}
	history, err := c.history(task, sha)
	if err != nil {
		return nil, err
	}
	plan.History = history
	return plan, nil
}

// history requires the commit an action moves to to DESCEND from the commit
// pinned today. A tag re-pointed at a commit outside the project's history --
// an orphan, a fork's -- is the shape of the 2025 tj-actions and reviewdog
// compromises, and a release cut from another branch is a decision too. Either
// way the compare view is what a person reads, so it is linked.
func (c *ApplyUpdatesCommand) history(task *entities.Task, sha string) (*entities.HistoryPlan, error) {
	url := fmt.Sprintf("https://github.com/%s/compare/%s...%s", task.Coord, task.CurrentSHA, sha)
	comparison, err := c.source.Compare(task.Coord, task.CurrentSHA, sha)
	if repositories.IsNotFound(err) {
		return nil, entities.Refuse(
			"GitHub cannot relate the release commit %s to the pinned %s in %s, so it may not be "+
				"part of the project's history: %s",
			sha[:digestPreview],
			task.CurrentSHA[:digestPreview],
			task.Coord,
			url,
		)
	}
	if err != nil {
		return nil, err
	}
	if !comparison.Descends() {
		return nil, entities.Refuse(
			"the release commit %s does not descend from the pinned %s (GitHub reports `%s`): a "+
				"re-pointed tag, or a release cut from another branch, needs a person to read the diff: %s",
			sha[:digestPreview],
			task.CurrentSHA[:digestPreview],
			comparison.Status,
			url,
		)
	}
	return &entities.HistoryPlan{
		Status: comparison.Status, AheadBy: comparison.AheadBy, Files: comparison.Files, CompareURL: url,
	}, nil
}

func (c *ApplyUpdatesCommand) prepareImage(task *entities.Task) (*entities.Plan, error) {
	if !entities.ImageDigest.MatchString(task.Latest) {
		return nil, entities.Refuse("the registry answered %q, which is not an image digest", task.Latest)
	}
	plan := &entities.Plan{New: task.Latest}
	if c.scanner == nil {
		return plan, nil
	}
	evidence, err := CompareImages(c.scanner, task.Coord, ProposedReference(task))
	if err != nil {
		return nil, err
	}
	if len(evidence.Introduced) > 0 {
		return nil, entities.Refuse(
			"the rebuild introduces %s",
			entities.DescribeFindings(evidence.Introduced, maxListed),
		)
	}
	plan.Image = evidence
	return plan, nil
}

// maxListed is how many findings a one-line message names before counting.
const maxListed = 5

// ProposedImage is `reference` re-pinned to `digest`.
func ProposedImage(reference, digest string) string {
	name, _, _ := strings.Cut(reference, "@")
	return name + "@" + digest
}

// ProposedReference is the reference an image update writes: the same name at
// the new digest, or -- for a `golang:` image whose pin moved -- the new tag's.
func ProposedReference(task *entities.Task) string {
	if task.Retag != "" {
		return task.Retag + "@" + task.Latest
	}
	return ProposedImage(task.Coord, task.Latest)
}

// CompareImages scans the image pinned today and the one proposed, and says
// what moving between them brings in and takes out.
func CompareImages(scanner repositories.ImageScannerRepository, current, proposed string) (*entities.ImagePlan, error) {
	before, err := scanner.Scan(current)
	if err != nil {
		return nil, err
	}
	after, err := scanner.Scan(proposed)
	if err != nil {
		return nil, err
	}
	if after.Skipped != "" {
		return &entities.ImagePlan{Skipped: after.Skipped}, nil
	}
	return &entities.ImagePlan{
		Introduced: entities.IntroducedFindings(before.Findings, after.Findings),
		Fixed:      entities.IntroducedFindings(after.Findings, before.Findings),
		Known:      len(after.Findings),
	}, nil
}

func (c *ApplyUpdatesCommand) write(task *entities.Task, targets map[string]string) error {
	switch task.Group {
	case entities.GroupManifest:
		return c.writeManifest(task, targets)
	case entities.GroupAction:
		for _, path := range c.workspace.YAMLFiles() {
			text, changes := entities.RepinAction(c.workspace.Text(path), task.Coord, task.Apply.SHA, task.Apply.New)
			if changes > 0 && c.workspace.Set(path, text) {
				task.Rewritten += changes
			}
		}
	case entities.GroupImage:
		name, _, _ := strings.Cut(task.Coord, "@")
		if task.Retag != "" {
			name = task.Retag
		}
		for _, path := range InlineFiles(c.workspace) {
			text, count := entities.RepinImage(c.workspace.Text(path), task.Coord, name+"@"+task.Apply.New)
			if count > 0 && c.workspace.Set(path, text) {
				task.Rewritten += count
			}
		}
	}
	return nil
}

// writeManifest rewrites the pin, every digest of it, and a vendored file, in
// one edit or not at all.
func (c *ApplyUpdatesCommand) writeManifest(task *entities.Task, targets map[string]string) error {
	plan := task.Apply
	text, err := entities.RewriteManifest(c.workspace.Text(entities.ManifestPath), *task.Entry, plan.New, plan.Digests)
	if err != nil {
		return err
	}
	if plan.Vendored != nil && !c.workspace.Set(plan.Vendored.Path, plan.Vendored.Merged) {
		return entities.Refuse("%s cannot be rewritten safely (a symlink, or not valid UTF-8)", plan.Vendored.Path)
	}
	if !c.workspace.Set(entities.ManifestPath, text) {
		return entities.Refuse("%s cannot be rewritten safely (a symlink, or not valid UTF-8)", entities.ManifestPath)
	}
	targets[task.Entry.Var] = plan.New
	for _, digest := range plan.Digests {
		targets[digest.Var] = digest.New
	}
	task.Rewritten = 1
	return nil
}

// alignCopies brings every inline copy to the value its manifest variable now
// holds, so a template with no SCRIPTS_DIR cannot be left behind on the version
// the manifest just left -- the Go inputs included, each to the pin of its line.
func (c *ApplyUpdatesCommand) alignCopies(
	manifest []entities.ManifestEntry,
	targets, before map[string]string,
) []entities.CopyChange {
	var fixes []entities.CopyChange
	for _, inline := range entities.InlineCopies() {
		want, tracked := targets[inline.Var]
		if !tracked {
			continue
		}
		previous, known := before[inline.Var]
		if !known {
			previous = want
		}
		for _, path := range InlineFiles(c.workspace) {
			text, changed := entities.AlignCopies(c.workspace.Text(path), inline, want, previous, path)
			if len(changed) > 0 && c.workspace.Set(path, text) {
				fixes = append(fixes, changed...)
			}
		}
	}
	return append(fixes, c.alignGoCopies(manifest, targets)...)
}

// alignGoCopies brings every Go input to the release the pin of its line now
// holds; nothing, in a repository that pins no Go.
func (c *ApplyUpdatesCommand) alignGoCopies(
	manifest []entities.ManifestEntry,
	targets map[string]string,
) []entities.CopyChange {
	if !entities.HasGoPins(manifest) {
		return nil
	}
	var fixes []entities.CopyChange
	for _, path := range InlineFiles(c.workspace) {
		text, changed := entities.AlignGoCopies(c.workspace.Text(path), path, manifest, targets)
		if len(changed) > 0 && c.workspace.Set(path, text) {
			fixes = append(fixes, changed...)
		}
	}
	return fixes
}
