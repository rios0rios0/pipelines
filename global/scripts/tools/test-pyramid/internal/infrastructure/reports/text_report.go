// Package reports renders a judgement for the log, the job summary, a JSON report and the per-file
// classification, and speaks each CI platform's annotation and summary dialect.
package reports

import (
	"fmt"
	"strconv"
	"strings"

	"github.com/rios0rios0/pipelines/global/scripts/tools/test-pyramid/internal/domain/entities"
)

// Text is the judgement for the job log.
func Text(report entities.Report) string {
	var text strings.Builder
	fmt.Fprintf(&text, "test-pyramid: comparing HEAD (%s) with %s (%s)\n",
		short(report.Head), Inert(report.Base.Description), short(report.Base.Commit))
	if report.Base.Warning != "" {
		fmt.Fprintf(&text, "test-pyramid: WARNING: %s\n", Inert(report.Base.Warning))
	}
	if report.PolicyChanged {
		text.WriteString("test-pyramid: this pull request changes .test-pyramid; a pull request is judged by its " +
			"target branch's, so the change applies once it is merged\n")
	}
	fmt.Fprintf(&text, "test-pyramid: policy from %s: blocking %t, reference mix %s, %d path rule(s)\n",
		policySource(report), report.Blocking, report.Policy.Mix, len(report.Policy.Rules))
	for _, suite := range report.Suites {
		writeSuite(&text, suite.Verdict)
	}
	return text.String()
}

func writeSuite(text *strings.Builder, verdict entities.Verdict) {
	fmt.Fprintf(text, "\ntest-pyramid [%s]:\n", verdict.Language)
	fmt.Fprintf(text, "  %-12s %8s %8s %8s\n", "tier", "target", "pr", "change")
	for _, tier := range entities.Tiers() {
		fmt.Fprintf(text, "  %-12s %8d %8d %8s\n", tier, verdict.Target.Of(tier), verdict.PullRequest.Of(tier),
			signed(verdict.PullRequest.Of(tier)-verdict.Target.Of(tier)))
	}
	fmt.Fprintf(text, "  %-12s %8d %8d %8s\n", "total", verdict.Target.Total(), verdict.PullRequest.Total(),
		signed(verdict.PullRequest.Total()-verdict.Target.Total()))
	fmt.Fprintf(text, "\n  shape: %s on the target branch, %s with this pull request\n",
		verdict.TargetShape(), verdict.PullRequestShape())
	if verdict.Mix.Judged {
		fmt.Fprintf(text, "  mix (unit / integration / functional+e2e): target %s, pr %s, reference %s\n",
			mixOf(verdict.Target), mixOf(verdict.PullRequest), verdict.Mix)
	} else {
		text.WriteString("  mix: not judged (mix off)\n")
	}
	for _, finding := range verdict.Findings {
		fmt.Fprintf(text, "  WORSENED  %s\n", finding)
	}
	if !verdict.Worsened() {
		text.WriteString("  kept: this pull request does not worsen the pyramid\n")
	}
}

// Inert is a name from outside -- a branch, a path -- reduced to what Markdown, a log line or an
// annotation cannot read as markup or as a new command: letters, digits, spaces and `._/-'":,()+=#`,
// any other character -- a newline, `%`, a backtick, `|`, `<` -- `?`.
func Inert(text string) string {
	const punctuation = " ._/-'\":,()+=#"
	return strings.Map(func(r rune) rune {
		switch {
		case r >= 'a' && r <= 'z', r >= 'A' && r <= 'Z', r >= '0' && r <= '9', strings.ContainsRune(punctuation, r):
			return r
		default:
			return '?'
		}
	}, text)
}

func policySource(report entities.Report) string {
	if report.PolicyFound {
		return ".test-pyramid on " + Inert(strconv.Quote(report.Target))
	}
	return "the defaults (no .test-pyramid on " + Inert(strconv.Quote(report.Target)) + ")"
}

func mixOf(counts entities.Counts) string {
	total := counts.Total()
	return entities.Share(counts.Of(entities.TierUnit), total) + " / " +
		entities.Share(counts.Of(entities.TierIntegration), total) + " / " +
		entities.Share(counts.AtOrAbove(entities.TierFunctional), total)
}

func signed(difference int) string {
	if difference > 0 {
		return "+" + strconv.Itoa(difference)
	}
	return strconv.Itoa(difference)
}

const shortCommit = 12

func short(commit string) string {
	return commit[:min(len(commit), shortCommit)]
}
