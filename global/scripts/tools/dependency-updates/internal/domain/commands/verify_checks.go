package commands

import (
	"fmt"
	"strings"

	"github.com/rios0rios0/pipelines/global/scripts/tools/dependency-updates/internal/domain/entities"
	"github.com/rios0rios0/pipelines/global/scripts/tools/dependency-updates/internal/domain/repositories"
)

// actionFindings prove an action's new pin is the commit its tag names, and
// that the commit descends from the one pinned before.
func (c *VerifyPullRequestCommand) actionFindings(item *change) []Finding {
	task := item.task
	if !entities.SafeTag.MatchString(task.Current) {
		return []Finding{{Verdict: VerdictFail, Check: CheckProvenance,
			Detail: fmt.Sprintf("the comment names %q, which is not a tag name this check will look up", task.Current)}}
	}
	sha, err := c.deps.Source.TagCommit(task.Coord, task.Current)
	switch {
	case repositories.IsNotFound(err):
		return []Finding{{Verdict: VerdictFail, Check: CheckProvenance,
			Detail: fmt.Sprintf("`%s` is not a tag of %s", task.Current, task.Coord)}}
	case err != nil:
		return []Finding{{Verdict: VerdictError, Check: CheckProvenance, Detail: err.Error()}}
	case sha != item.sha:
		return []Finding{{Verdict: VerdictFail, Check: CheckProvenance, Detail: fmt.Sprintf(
			"the comment says `%s`, which points at `%s`, but the pin is `%s`: the commit is not the release it claims to be",
			task.Current,
			sha[:digestPreview],
			item.sha[:digestPreview],
		)}}
	}
	findings := []Finding{{Verdict: VerdictPass, Check: CheckProvenance,
		Detail: fmt.Sprintf("`%s` is the commit `%s` points at", sha[:digestPreview], task.Current)}}
	return append(findings, c.historyFinding(item, sha))
}

func (c *VerifyPullRequestCommand) historyFinding(item *change, sha string) Finding {
	if item.baseTask == nil || item.baseTask.CurrentSHA == "" {
		return Finding{Verdict: VerdictWarn, Check: CheckHistory,
			Detail: "a new action: nothing was pinned before to compare it with, so review it as a new dependency"}
	}
	base := item.baseTask.CurrentSHA
	if base == sha {
		return Finding{Verdict: VerdictPass, Check: CheckHistory, Detail: "the same commit as before"}
	}
	url := fmt.Sprintf("https://github.com/%s/compare/%s...%s", item.task.Coord, base, sha)
	comparison, err := c.deps.Source.Compare(item.task.Coord, base, sha)
	switch {
	case repositories.IsNotFound(err):
		return Finding{
			Verdict: VerdictFail,
			Check:   CheckHistory,
			Detail:  "GitHub cannot relate the new commit to the one pinned before, so it may not be part of the project's history: " + url,
		}
	case err != nil:
		return Finding{Verdict: VerdictError, Check: CheckHistory, Detail: err.Error()}
	case !comparison.Descends():
		return Finding{Verdict: VerdictFail, Check: CheckHistory, Detail: fmt.Sprintf(
			"the new commit does not descend from the one pinned before (GitHub reports `%s`): a re-pointed tag, or a "+
				"release cut from another branch, needs a person to read the diff: %s", comparison.Status, url)}
	default:
		return Finding{
			Verdict: VerdictPass,
			Check:   CheckHistory,
			Detail: fmt.Sprintf("%d commit(s) ahead of the pinned "+
				"commit, %d file(s) changed: %s", comparison.AheadBy, comparison.Files, url),
		}
	}
}

// manifestFindings check a manifest pin's bounds and integrity, and a vendored
// file's merge.
func (c *VerifyPullRequestCommand) manifestFindings(item *change, headManifest []entities.ManifestEntry) []Finding {
	task := item.task
	findings := boundsFindings(item, headManifest)
	if !entities.SafeVersion.MatchString(task.Current) {
		return append(findings, Finding{Verdict: VerdictFail, Check: CheckBounds,
			Detail: fmt.Sprintf("%q is not safe to write into a sourced shell file", task.Current)})
	}
	findings = append(findings, c.integrityFindings(task)...)
	if task.Entry.Vendored != "" && item.baseEntry != nil && item.baseEntry.Current != task.Current {
		findings = append(findings, c.vendoredFinding(item))
	}
	return findings
}

func boundsFindings(item *change, headManifest []entities.ManifestEntry) []Finding {
	task := item.task
	var findings []Finding
	if task.Track != "" && !entities.InLine(task.Current, task.Track) {
		findings = append(findings, Finding{Verdict: VerdictFail, Check: CheckBounds, Detail: fmt.Sprintf(
			"`%s` is outside %s, which the pin is held to (`track=%s`)",
			task.Current,
			entities.LineName(task.Track),
			task.Track,
		)})
	}
	if ceiling := ceilingOf(task, headManifest); ceiling != "" && entities.IsNewer(ceiling, task.Current) {
		findings = append(findings, Finding{Verdict: VerdictFail, Check: CheckBounds, Detail: fmt.Sprintf(
			"`%s` moves past `%s` `%s`, which it may never exceed (`ceiling=%s`)", task.Current, task.Entry.Ceiling,
			ceiling, task.Entry.Ceiling)})
	}
	if item.baseEntry != nil && entities.IsTaggedKind(task.Kind) {
		before, _ := entities.TagFamily(item.baseEntry.Current)
		after, _ := entities.TagFamily(task.Current)
		if before != after {
			findings = append(findings, Finding{Verdict: VerdictFail, Check: CheckBounds, Detail: fmt.Sprintf(
				"moves from the `%s` release line to `%s`", before, after)})
		}
	}
	return findings
}

// integrityFindings re-derive every committed digest from the release itself,
// and cross-check the publisher's checksum manifest.
func (c *VerifyPullRequestCommand) integrityFindings(task *entities.Task) []Finding {
	if len(task.Entry.Digests) == 0 {
		detail := "no digest: installed by exact version from its registry"
		if task.Entry.Image != "" {
			detail = "no digest: each copy of `" + task.Entry.Image + "` carries its own, checked against the registry"
		}
		return []Finding{{Verdict: VerdictPass, Check: CheckIntegrity, Detail: detail}}
	}
	var findings []Finding
	for _, check := range NewVerifyAssetsCommand(c.deps.Artifacts).Entry(*task.Entry, task.Current) {
		verdict := VerdictFail
		switch check.Status {
		case AssetOK:
			verdict = VerdictPass
		case AssetError:
			verdict = VerdictError
		}
		findings = append(
			findings,
			Finding{Verdict: verdict, Check: CheckIntegrity, Detail: "`" + check.Name + "`: " + check.Detail},
		)
	}
	return findings
}

// vendoredFinding requires a vendored file to be EXACTLY upstream's change
// merged onto the adjustments the base carried. A dependency bump that also
// edits the file some other way smuggles a change review was not asked about.
func (c *VerifyPullRequestCommand) vendoredFinding(item *change) Finding {
	head, base := item.task.Entry, item.baseEntry
	if len(head.Digests) != 1 || len(base.Digests) != 1 || head.Digests[0].Asset == "" || base.Digests[0].Asset == "" {
		return Finding{Verdict: VerdictFail, Check: CheckVendored,
			Detail: "a vendored pin must carry exactly one annotated digest on both sides"}
	}
	baseUpstream, err := c.deps.Artifacts.Content(entities.Render(base.Digests[0].Asset, base.Current))
	if err != nil {
		return lookupFinding(CheckVendored, err)
	}
	if entities.SHA256Hex(baseUpstream) != base.Digests[0].Value {
		return Finding{Verdict: VerdictFail, Check: CheckVendored, Detail: fmt.Sprintf(
			"upstream's file at `%s` is not the one the base's committed digest names, so the merge cannot be reproduced",
			base.Current,
		)}
	}
	headUpstream, err := c.deps.Artifacts.Content(entities.Render(head.Digests[0].Asset, head.Current))
	if err != nil {
		return lookupFinding(CheckVendored, err)
	}
	if entities.DeclaresPlugin(string(headUpstream)) && !entities.DeclaresPlugin(string(baseUpstream)) {
		return Finding{Verdict: VerdictFail, Check: CheckVendored, Detail: fmt.Sprintf(
			"upstream `%s` declares a custom linter plugin: code that would run in every consumer's lint job",
			head.Current,
		)}
	}
	merged, conflicts, err := c.deps.Merger.Merge(
		c.deps.Base.Text(head.Vendored),
		string(baseUpstream),
		string(headUpstream),
	)
	switch {
	case err != nil:
		return Finding{Verdict: VerdictError, Check: CheckVendored, Detail: err.Error()}
	case conflicts > 0:
		return Finding{Verdict: VerdictFail, Check: CheckVendored, Detail: fmt.Sprintf(
			"upstream's change from `%s` to `%s` does not merge cleanly onto the base's adjustments",
			base.Current,
			head.Current,
		)}
	case c.deps.Head.Text(head.Vendored) != merged:
		return Finding{Verdict: VerdictFail, Check: CheckVendored, Detail: fmt.Sprintf(
			"`%s` is not upstream's change from `%s` to `%s` merged onto the base's adjustments: it carries edits the "+
				"version bump does not explain, which belong in a pull request of their own", head.Vendored, base.Current, head.Current)}
	}
	detail := fmt.Sprintf("`%s` is exactly upstream's change from `%s` to `%s`, merged onto the base's adjustments",
		head.Vendored, base.Current, head.Current)
	if enabled, disabled := entities.LinterChanges(
		string(baseUpstream),
		string(headUpstream),
	); len(
		enabled,
	)+len(
		disabled,
	) > 0 {
		detail += fmt.Sprintf("; it switches on %s and off %s", orNone(enabled), orNone(disabled))
	}
	return Finding{Verdict: VerdictPass, Check: CheckVendored, Detail: detail}
}

func orNone(names []string) string {
	if len(names) == 0 {
		return "nothing"
	}
	return "`" + strings.Join(names, "`, `") + "`"
}

func lookupFinding(check string, err error) Finding {
	if repositories.IsNotFound(err) {
		return Finding{Verdict: VerdictFail, Check: check, Detail: err.Error()}
	}
	return Finding{Verdict: VerdictError, Check: check, Detail: err.Error()}
}
