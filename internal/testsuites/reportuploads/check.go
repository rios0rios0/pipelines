package main

import (
	"fmt"
	"io"
	"os"
	"path"
	"path/filepath"
	"regexp"
	"sort"
	"strings"

	"github.com/rios0rios0/pipelines/internal/testsuites/yamldoc"
)

// deliverables are stages whose uploaded files ARE the job's product rather than
// a report about it: a failed upload means nothing was delivered.
func deliverables() map[string]bool {
	return map[string]bool{
		"github/dart/stages/40-delivery/build/action.yaml": true,
	}
}

// mandatory are stages whose tool must leave a report behind when it exits 0;
// each carries a `Verify Report` step immediately before its upload.
func mandatory() map[string]bool {
	return map[string]bool{
		"github/global/stages/20-security/gitleaks/action.yaml":    true,
		"github/global/stages/20-security/semgrep/action.yaml":     true,
		"github/golang/stages/20-security/govulncheck/action.yaml": true,
		"github/java/stages/10-code-check/proguard/action.yaml":    true,
		"github/javascript/stages/10-code-check/knip/action.yaml":  true,
		"github/python/stages/10-code-check/vulture/action.yaml":   true,
	}
}

// boundedRetention is the one shape a `retention-days` may take: the stage's own
// number of days, or the repository's retention when that is shorter. A bare
// number above the repository's retention is cut to it by `actions/upload-artifact`
// anyway, with a warning annotation on every run.
var boundedRetention = regexp.MustCompile(
	`^\$\{\{ github\.retention_days < (\d+) && github\.retention_days \|\| (\d+) \}\}$`)

// stepList is one list of steps and where it sits, as a finding names it.
type stepList struct {
	where string
	steps []*yamldoc.Node
}

// stepLists are a file's composite steps and each of its jobs' steps.
func stepLists(relative string, document *yamldoc.Node) []stepList {
	var lists []stepList
	if runs := document.Get("runs"); runs.Get("using").Is("composite") {
		lists = append(lists, stepList{where: relative, steps: runs.Get("steps").Items()})
	}
	for _, job := range document.Get("jobs").Pairs() {
		lists = append(lists, stepList{
			where: fmt.Sprintf("%s :: job %s", relative, job.Key.Str()),
			steps: job.Value.Get("steps").Items(),
		})
	}
	return lists
}

type checker struct {
	findings []string
	verified map[string]bool
}

func (c *checker) report(kind, finding string) {
	c.findings = append(c.findings, kind+"\t"+finding)
}

// check reads every composite action and workflow under `root` and writes the
// findings.
func check(root string, output io.Writer) error {
	files, err := filesInScope(root)
	if err != nil {
		return err
	}
	c := &checker{verified: map[string]bool{}}
	for _, relative := range files {
		document, loadErr := yamldoc.Load(filepath.Join(root, filepath.FromSlash(relative)), yamldoc.Options{})
		if loadErr != nil {
			return fmt.Errorf("%s: %w", relative, loadErr)
		}
		for _, list := range stepLists(relative, document) {
			for index, step := range list.steps {
				c.checkUpload(relative, list, index, step)
			}
		}
	}
	required := mandatory()
	for _, relative := range sortedDifference(required, c.verified) {
		c.report("verify", relative+" has no `Verify Report` step right before its upload")
	}
	for _, relative := range sortedDifference(c.verified, required) {
		c.report("verify", relative+" has a `Verify Report` step but is missing from MANDATORY in this test")
	}
	for _, finding := range c.findings {
		if _, err = fmt.Fprintln(output, finding); err != nil {
			return err
		}
	}
	return nil
}

func (c *checker) checkUpload(relative string, list stepList, index int, step *yamldoc.Node) {
	if !strings.HasPrefix(step.Get("uses").StrOr(""), "actions/upload-artifact@") {
		return
	}
	label := fmt.Sprintf("%s :: step %d (%s)", list.where, index, step.Get("name").StrOr("unnamed"))
	optional := step.Get("continue-on-error").IsTrue()
	with := step.Get("with")
	c.checkRetention(label, with)
	if deliverables()[relative] {
		if optional {
			c.report("deliverable", label+" uploads the job's product but is continue-on-error")
		}
		return
	}
	if !optional {
		c.report("optional", label+" is not continue-on-error")
	}
	if optional && with.Get("if-no-files-found").Is("error") {
		c.report("silent", label+" says `if-no-files-found: error` under continue-on-error, which fails nothing")
	}
	if index == 0 {
		return
	}
	previous := list.steps[index-1]
	if !previous.Get("name").Is("Verify Report") {
		return
	}
	c.verified[relative] = true
	if previous.Has("if") {
		c.report("verify", label+": `Verify Report` must run on the default success() condition")
	}
	expected := strings.TrimRight(with.Get("path").StrOr(""), "/")
	actual := previous.Get("env").Get("REPORT_DIR").StrOr("")
	if actual != expected {
		c.report("verify", fmt.Sprintf("%s: `Verify Report` checks %s, the upload publishes %s",
			label, yamldoc.Quote(actual), yamldoc.Quote(expected)))
	}
}

// checkRetention reports an upload that asks to keep its files for a number of
// days the repository's retention does not bound. Leaving `retention-days` out is
// fine: the upload then keeps the repository's own retention.
func (c *checker) checkRetention(label string, with *yamldoc.Node) {
	if !with.Has("retention-days") {
		return
	}
	days := with.Get("retention-days").StrOr("")
	if bound := boundedRetention.FindStringSubmatch(days); bound != nil && bound[1] == bound[2] {
		return
	}
	c.report("retention", fmt.Sprintf("%s asks for retention-days %s, unbounded by the repository's retention",
		label, yamldoc.Quote(days)))
}

// filesInScope are every `action.yaml` at any depth under github/ and every
// `*.yaml` directly in .github/workflows/, sorted, the way a shell glob lists
// them: hidden entries are never matched.
func filesInScope(root string) ([]string, error) {
	var files []string
	if err := collectActions(root, "github", &files); err != nil {
		return nil, err
	}
	entries, err := os.ReadDir(filepath.Join(root, ".github", "workflows"))
	if err != nil {
		return nil, err
	}
	for _, entry := range entries {
		if !strings.HasPrefix(entry.Name(), ".") && strings.HasSuffix(entry.Name(), ".yaml") {
			files = append(files, path.Join(".github/workflows", entry.Name()))
		}
	}
	sort.Strings(files)
	return files, nil
}

func collectActions(root, directory string, files *[]string) error {
	entries, err := os.ReadDir(filepath.Join(root, filepath.FromSlash(directory)))
	if err != nil {
		return err
	}
	for _, entry := range entries {
		name := entry.Name()
		switch {
		case strings.HasPrefix(name, "."):
		case entry.IsDir():
			if err = collectActions(root, path.Join(directory, name), files); err != nil {
				return err
			}
		case name == "action.yaml":
			*files = append(*files, path.Join(directory, name))
		}
	}
	return nil
}

func sortedDifference(from, without map[string]bool) []string {
	var left []string
	for name := range from {
		if !without[name] {
			left = append(left, name)
		}
	}
	sort.Strings(left)
	return left
}
