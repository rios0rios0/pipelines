package reports

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
)

// Platform is the CI service the check runs on, as the environment it sets tells: GitHub Actions
// (`GITHUB_ACTIONS`), Azure DevOps (`TF_BUILD`), or anything else, GitLab CI included, which has
// neither annotations nor an uploaded summary and reads the job log and the report artifact.
type Platform struct {
	gitHub      bool
	azure       bool
	stepSummary string
}

// DetectPlatform is the platform `getenv` describes.
func DetectPlatform(getenv func(string) string) Platform {
	return Platform{
		gitHub:      getenv("GITHUB_ACTIONS") == "true",
		azure:       getenv("TF_BUILD") != "",
		stepSummary: getenv("GITHUB_STEP_SUMMARY"),
	}
}

// Annotate writes an annotation of `level` (`warning` or `error`) onto the run, where the platform
// has them; the message is made inert first, so it cannot close the annotation or open another.
func (p Platform) Annotate(stdout io.Writer, level, message string) {
	message = Inert(message)
	switch {
	case p.gitHub:
		_, _ = fmt.Fprintf(stdout, "::%s title=Test pyramid::%s\n", level, message)
	case p.azure:
		_, _ = fmt.Fprintf(stdout, "##vso[task.logissue type=%s]%s\n", level, message)
	}
}

// PublishSummary puts the Markdown summary where the platform shows it: appended to GitHub's job
// summary, or uploaded to the Azure DevOps run's summary tab.
func (p Platform) PublishSummary(stdout io.Writer, summaryPath string) error {
	if p.gitHub && p.stepSummary != "" {
		content, err := os.ReadFile(filepath.Clean(summaryPath))
		if err != nil {
			return err
		}
		summary, err := os.OpenFile(p.stepSummary, os.O_APPEND|os.O_CREATE|os.O_WRONLY, reportFileMode)
		if err != nil {
			return err
		}
		_, writeErr := summary.Write(content)
		closeErr := summary.Close()
		if writeErr != nil {
			return writeErr
		}
		return closeErr
	}
	if p.azure {
		absolute, err := filepath.Abs(summaryPath)
		if err != nil {
			return err
		}
		_, _ = fmt.Fprintf(stdout, "##vso[task.uploadsummary]%s\n", strings.ReplaceAll(absolute, "\n", ""))
	}
	return nil
}
