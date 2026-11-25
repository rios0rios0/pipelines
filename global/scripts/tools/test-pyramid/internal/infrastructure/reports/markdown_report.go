package reports

import (
	"fmt"
	"strings"

	"github.com/rios0rios0/pipelines/global/scripts/tools/test-pyramid/internal/domain/entities"
)

// Markdown is the judgement for the job summary and the pull request.
func Markdown(report entities.Report) string {
	var markdown strings.Builder
	markdown.WriteString("## Test pyramid\n\n")
	if worsened := report.Worsened(); len(worsened) > 0 {
		fmt.Fprintf(
			&markdown,
			"This pull request **worsens** the test pyramid of: %s.\n\n",
			strings.Join(worsened, ", "),
		)
	} else {
		markdown.WriteString("This pull request keeps the test pyramid.\n\n")
	}
	fmt.Fprintf(&markdown, "Compared with %s (`%s`). Policy: %s; blocking: `%t`.\n\n",
		Inert(report.Base.Description), short(report.Base.Commit), policySource(report), report.Blocking)
	if report.Base.Warning != "" {
		fmt.Fprintf(&markdown, "> **Warning:** %s\n\n", Inert(report.Base.Warning))
	}
	for _, suite := range report.Suites {
		writeMarkdownSuite(&markdown, suite.Verdict)
	}
	markdown.WriteString("Each test file is in one tier, decided in this order: a path rule of `.test-pyramid`, " +
		"then what the file declares or uses (a build tag, a test category, a browser driver, an in-process HTTP " +
		"client, a container), then its path, else unit. The per-file decisions are in the `test-pyramid` report.\n")
	return markdown.String()
}

func writeMarkdownSuite(markdown *strings.Builder, verdict entities.Verdict) {
	outcome := "keeps the test pyramid"
	if verdict.Worsened() {
		outcome = "worsens the test pyramid"
	}
	fmt.Fprintf(markdown, "### `%s`: %s\n\n", verdict.Language, outcome)
	markdown.WriteString("| Tier | Target branch | This pull request | Change |\n|---|---:|---:|---:|\n")
	for _, tier := range entities.Tiers() {
		fmt.Fprintf(markdown, "| %s | %d (%s) | %d (%s) | %s |\n", tier,
			verdict.Target.Of(tier), entities.Share(verdict.Target.Of(tier), verdict.Target.Total()),
			verdict.PullRequest.Of(tier), entities.Share(verdict.PullRequest.Of(tier), verdict.PullRequest.Total()),
			signed(verdict.PullRequest.Of(tier)-verdict.Target.Of(tier)))
	}
	fmt.Fprintf(markdown, "| **total** | %d | %d | %s |\n\n", verdict.Target.Total(), verdict.PullRequest.Total(),
		signed(verdict.PullRequest.Total()-verdict.Target.Total()))
	fmt.Fprintf(markdown, "Shape: **%s** on the target branch, **%s** with this pull request. ",
		verdict.TargetShape(), verdict.PullRequestShape())
	if verdict.Mix.Judged {
		fmt.Fprintf(markdown, "Reference mix (unit / integration / functional+e2e): %s.\n\n", verdict.Mix)
	} else {
		markdown.WriteString("The mix is not judged (`mix off`).\n\n")
	}
	for _, finding := range verdict.Findings {
		fmt.Fprintf(markdown, "- %s\n", finding)
	}
	if verdict.Worsened() {
		markdown.WriteString("\n")
	}
}
