package reports

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/rios0rios0/pipelines/global/scripts/tools/test-pyramid/internal/domain/entities"
)

const (
	reportFileMode      = 0o644
	reportDirectoryMode = 0o755
)

// Classification is a tree's per-file decisions, as tab-separated values: the audit trail that
// says, for every test file, which tier it was put in and which rule put it there.
func Classification(classification entities.Classification) string {
	var tsv strings.Builder
	tsv.WriteString("tier\tcases\treason\tpath\n")
	flatten := strings.NewReplacer("\t", " ", "\n", " ")
	for _, file := range classification.Files {
		fmt.Fprintf(&tsv, "%s\t%d\t%s\t%s\n", file.Tier, file.Cases, file.Reason, flatten.Replace(file.Path))
	}
	return tsv.String()
}

// Write writes every report into `directory` -- `summary.md`, `test-pyramid.json`, and each
// language's `<language>-target.tsv` and `<language>-pull-request.tsv` -- and is the summary's path.
func Write(report entities.Report, directory string) (string, error) {
	if err := os.MkdirAll(directory, reportDirectoryMode); err != nil {
		return "", err
	}
	document, err := JSON(report)
	if err != nil {
		return "", err
	}
	files := map[string]string{
		"summary.md":        Markdown(report),
		"test-pyramid.json": string(document) + "\n",
	}
	for _, suite := range report.Suites {
		files[suite.Verdict.Language+"-target.tsv"] = Classification(suite.Target)
		files[suite.Verdict.Language+"-pull-request.tsv"] = Classification(suite.PullRequest)
	}
	for name, content := range files {
		if writeErr := os.WriteFile(filepath.Join(directory, name), []byte(content), reportFileMode); writeErr != nil {
			return "", fmt.Errorf("cannot write %s: %w", name, writeErr)
		}
	}
	return filepath.Join(directory, "summary.md"), nil
}
