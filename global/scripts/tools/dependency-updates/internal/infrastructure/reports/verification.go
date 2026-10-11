package reports

import (
	"fmt"
	"slices"
	"strings"

	"github.com/rios0rios0/pipelines/global/scripts/tools/dependency-updates/internal/domain/commands"
	"github.com/rios0rios0/pipelines/global/scripts/tools/dependency-updates/internal/domain/entities"
)

// VerificationMarker identifies the verification comment, so a rerun updates it
// rather than adding another.
const VerificationMarker = "<!-- dependency-updates-verification -->"

func verdictIcon(verdict string) string {
	switch verdict {
	case commands.VerdictPass:
		return "PASS"
	case commands.VerdictWarn:
		return "WARN"
	case commands.VerdictFail:
		return "**FAIL**"
	default:
		return "**ERROR**"
	}
}

// Verification is the pull request verification's report: the job summary, and
// the comment that is the visible proof on the pull request itself.
func Verification(result commands.VerifyResult) string {
	lines := []string{VerificationMarker, "# Supply-chain verification", ""}
	lines = append(lines, verificationHeadline(result), "")
	lines = append(lines, changesTable(result.Changes)...)
	lines = append(lines, changeDetails(result.Changes)...)
	lines = append(lines, verificationTail(result)...)
	if slices.ContainsFunc(result.Changes, func(change commands.VerifiedChange) bool {
		return change.Group == entities.GroupImage
	}) {
		lines = append(lines,
			"The **scan** check exports both images straight from the registry, verifies every layer "+
				"against its digest, and scans them with OSV-Scanner: a rebuild that introduces a known "+
				"vulnerability fails, and the ones it fixes are listed.",
		)
	}
	return strings.Join(lines, "\n") + "\n"
}

func changesTable(changes []commands.VerifiedChange) []string {
	if len(changes) == 0 {
		return nil
	}
	lines := table("dependency", "from", "to", "verdict")
	for _, change := range changes {
		from, to := change.From, change.To
		if from == "" {
			from = "--"
		}
		if change.Group == entities.GroupImage {
			from, to = ShortDigest(from), ShortDigest(to)
		}
		lines = append(lines, fmt.Sprintf("| %s | `%s` | `%s` | %s |",
			changeName(change), MDSafe(from), MDSafe(to), verdictIcon(change.Verdict())))
	}
	return append(lines, "")
}

// changeName names a change in Markdown: the dependency, or both names of an
// image moved to another tag. A name is read from the pull request's own diff
// -- a fork's, possibly -- so it is made inert like any upstream value.
func changeName(change commands.VerifiedChange) string {
	if change.Retagged != "" {
		return "`" + MDSafe(change.Retagged) + "` -> `" + MDSafe(change.Label) + "`"
	}
	return "`" + MDSafe(change.Label) + "`"
}

// changeNameHTML is changeName inside a `<summary>`, which is HTML.
func changeNameHTML(change commands.VerifiedChange) string {
	if change.Retagged != "" {
		return "<code>" + MDSafe(change.Retagged) + "</code> -&gt; <code>" + MDSafe(change.Label) + "</code>"
	}
	return "<code>" + MDSafe(change.Label) + "</code>"
}

// consoleName is changeName for a terminal.
func consoleName(change commands.VerifiedChange) string {
	if change.Retagged != "" {
		return change.Retagged + " -> " + change.Label
	}
	return change.Label
}

func changeDetails(changes []commands.VerifiedChange) []string {
	var lines []string
	for _, change := range changes {
		lines = append(lines,
			"<details><summary>"+changeNameHTML(change)+": "+verdictIcon(change.Verdict())+"</summary>", "")
		for _, finding := range change.Findings {
			lines = append(lines,
				fmt.Sprintf("- %s **%s**: %s", verdictIcon(finding.Verdict), finding.Check, MDText(finding.Detail)))
		}
		lines = append(lines, "", "</details>", "")
	}
	return lines
}

func verificationTail(result commands.VerifyResult) []string {
	var lines []string
	if result.AdvisoryError != "" {
		lines = append(lines, "## Advisory lookup failed", "",
			"The known-vulnerability database could not be consulted, so nothing here is proven safe:", "",
			"- "+MDSafe(result.AdvisoryError), "")
	}
	if len(result.Vulnerable) > 0 {
		lines = append(lines, "## Known vulnerabilities in pins on this branch", "",
			"Already present before this pull request unless a change above says otherwise; the scheduled run "+
				"proposes each fix as soon as one is released, and stays red until it is merged.", "")
		for _, task := range SortedTasks(result.Vulnerable) {
			lines = append(lines,
				fmt.Sprintf("- `%s` `%s`: %s", task.Label, task.Security.Version, AdvisoryList(task.Security.Current)))
		}
		lines = append(lines, "")
	}
	if len(result.Drift) > 0 {
		lines = append(lines, "## Copies this pull request leaves out of step", "",
			"Each copy below no longer names what the pin it mirrors does, and did on the base branch: a pin moved "+
				"without its copies, or a copy edited away from its pin.", "")
		lines = append(lines, table("pin", "file", "copy", "pin")...)
		for _, row := range result.Drift {
			lines = append(lines, codeRow(row.Name, row.File, row.Inline, row.Manifest))
		}
		lines = append(lines, "")
	}
	if len(result.Untracked) > 0 {
		lines = append(lines, "## Pins nothing can check", "")
		for _, row := range result.Untracked {
			lines = append(lines, fmt.Sprintf("- `%s`: no `# %s:` annotation", row.Name, row.Missing))
		}
		lines = append(lines, "")
	}
	return lines
}

func verificationHeadline(result commands.VerifyResult) string {
	switch {
	case len(result.Changes) == 0 && len(result.Drift) == 0:
		return "This pull request moves no pinned dependency: nothing to verify."
	case len(result.Changes) == 0:
		return "**Not verified:** this pull request moves no pinned dependency, but leaves copies of one out of step " +
			"with its pin."
	}
	switch result.Exit() {
	case 0:
		return fmt.Sprintf("**Verified:** every one of the %s this pull request moves passed: no known vulnerability "+
			"or malicious release is introduced, every release is past the cooldown or fixes a known vulnerability, "+
			"and every digest, commit and vendored file is the one upstream published.",
			Plural(len(result.Changes), "pinned dependency", "pinned dependencies"))
	case 1:
		return "**Not verified:** at least one change or copy below failed a check, and must not be merged as it is."
	default:
		return "**Not verified:** something below could not be checked, and an unproven change is not a passing one."
	}
}

// Verification lists a verification's verdicts on the console.
func (c *Console) Verification(result commands.VerifyResult) {
	if len(result.Changes) == 0 {
		c.Printf("No pinned dependency changed: nothing to verify.\n")
	}
	for _, change := range result.Changes {
		c.Printf("  %-6s %-52s %s -> %s\n", change.Verdict(), consoleName(change), change.From, change.To)
		for _, finding := range change.Findings {
			if finding.Verdict != commands.VerdictPass {
				c.Printf("           %-11s %s\n", finding.Check, finding.Detail)
			}
		}
	}
	for _, row := range result.Drift {
		c.Printf("  FAIL   %-52s %s has %s, the pin says %s\n", row.Name, row.File, row.Inline, row.Manifest)
	}
	if result.AdvisoryError != "" {
		c.Errorf("  ERROR  advisory database: %s\n", result.AdvisoryError)
	}
}
