package main

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"

	"github.com/rios0rios0/pipelines/internal/testsuites/filetext"
	"github.com/rios0rios0/pipelines/internal/testsuites/yamldoc"
)

// scope is what every project-scoped step must receive.
const scope = "${{ inputs.working_directory }}"

// The shared SonarQube runner, and the variable that tells it where the project is.
const (
	sonarRunner     = "global/scripts/tools/sonarqube/run.sh"
	sonarProjectDir = "SONAR_PROJECT_DIR"
)

// projectScript is where the scripts that drive a project's own toolchain live.
const projectScript = "/global/scripts/languages/"

var (
	// projectCommand is a `run:` line that drives the project's own toolchain.
	// Anchored at the start of a line so the Corepack guard (`... || npm i -g
	// corepack`), which installs a global shim and is genuinely
	// path-independent, is not swept in with the installs.
	projectCommand = regexp.MustCompile(`(?m)^[[:space:]]*(npm|yarn|bundle|gem exec)\b`)
	// rootRelativeReport is a report path left relative to the workspace root.
	rootRelativeReport = regexp.MustCompile(`^(\./)?(coverage|junit-report|build|vite\.config)`)
)

// bases are the toolchain workflows that accept the input, each with the base
// workflow a variant calls ("" for a base itself).
func bases() map[string]string {
	return map[string]string{
		"bundler.yaml":         "",
		"npm.yaml":             "",
		"yarn.yaml":            "",
		"bundler-library.yaml": "bundler",
		"bundler-docker.yaml":  "bundler",
		"npm-library.yaml":     "npm",
		"npm-docker.yaml":      "npm",
		"yarn-library.yaml":    "yarn",
		"yarn-docker.yaml":     "yarn",
	}
}

// actions are the composite stages that run a project command and therefore
// take the same input.
func actions() []string {
	return []string{
		"github/javascript/stages/10-code-check/format/action.yaml",
		"github/javascript/stages/10-code-check/knip/action.yaml",
	}
}

// repositoryWide are the jobs that scan the REPOSITORY and must never be scoped
// to the project. `code_check-basic_checks` reads the changelog and the
// branch's ancestry, neither of which is in the project.
func repositoryWide() map[string]bool {
	return map[string]bool{
		"code_check-basic_checks": true,
		"security-sast_codeql":    true,
		"security-sast_semgrep":   true,
		"security-sast_gitleaks":  true,
		"security-sast_hadolint":  true,
	}
}

// reportPathKeys are the `with:` inputs that name a report path.
func reportPathKeys() []string {
	return []string{"json-summary-path", "json-final-path", "vite-config-path", "path"}
}

type checker struct {
	root     string
	findings []string
}

func (c *checker) emit(group, message string) {
	c.findings = append(c.findings, group+"\t"+message)
}

// check reads every file in scope under `root` once and writes the findings.
func check(root string, output io.Writer) error {
	c := &checker{root: root}
	if err := c.checkWorkflows(); err != nil {
		return err
	}
	if err := c.checkActions(); err != nil {
		return err
	}
	if err := c.checkSonarRunner(); err != nil {
		return err
	}
	for _, finding := range c.findings {
		if _, err := fmt.Fprintln(output, finding); err != nil {
			return err
		}
	}
	return nil
}

func isFile(path string) bool {
	info, err := os.Stat(path)
	return err == nil && info.Mode().IsRegular()
}

// declares holds the input to being OPTIONAL and rooted at `.`, or every
// existing consumer of the workflow becomes a validation error on the next run.
func (c *checker) declares(name string, spec *yamldoc.Node) {
	if spec.Kind() == yamldoc.Null {
		c.emit("declared", name+" does not declare `working_directory`")
		return
	}
	if !spec.Get("required").IsFalseOrNull() {
		c.emit("declared", name+" declares `working_directory` as required")
	}
	if !spec.Get("default").Is(".") {
		c.emit("declared", fmt.Sprintf("%s defaults `working_directory` to %s, not %s",
			name, spec.Get("default").Repr(), yamldoc.Quote(".")))
	}
}

func (c *checker) checkWorkflows() error {
	table := bases()
	names := make([]string, 0, len(table))
	for name := range table {
		names = append(names, name)
	}
	sort.Strings(names)
	for _, name := range names {
		path := filepath.Join(c.root, ".github", "workflows", name)
		if !isFile(path) {
			c.emit("declared", name+" is missing entirely")
			continue
		}
		document, err := yamldoc.Load(path, yamldoc.Options{})
		if err != nil {
			return fmt.Errorf("%s: %w", path, err)
		}
		inputs := document.Get("on").Get("workflow_call").Get("inputs")
		spec := inputs.Get("working_directory")
		c.declares(name, spec)
		if kind := spec.Get("type"); kind.Kind() != yamldoc.Null && !kind.Is("string") {
			c.emit("declared", fmt.Sprintf("%s types `working_directory` as %s rather than string", name, kind.Repr()))
		}
		if base := table[name]; base != "" {
			c.checkForwarded(name, base, document.Get("jobs"))
			continue
		}
		for _, job := range document.Get("jobs").Pairs() {
			for index, step := range job.Value.Get("steps").Items() {
				c.checkWorkflowStep(fmt.Sprintf("%s :: %s :: step %d", name, job.Key.Str(), index), job.Key.Str(), step)
			}
		}
	}
	return nil
}

// checkForwarded holds a variant to passing the input on: one that declares it
// and forgets to forward it accepts the value and silently ignores it.
func (c *checker) checkForwarded(name, base string, jobs *yamldoc.Node) {
	for _, job := range jobs.Pairs() {
		uses := text(job.Value.Get("uses"))
		if strings.HasSuffix(uses, "/.github/workflows/"+base+".yaml@main") &&
			job.Value.Get("with").Get("working_directory").Is(scope) {
			return
		}
	}
	c.emit("forwarded", fmt.Sprintf("%s does not pass `working_directory` to %s.yaml", name, base))
}

// text is a value as the checks compare it: its text when it is set, "" when it is not.
func text(node *yamldoc.Node) string {
	if !node.Truthy() {
		return ""
	}
	return node.Str()
}

func (c *checker) checkWorkflowStep(where, job string, step *yamldoc.Node) {
	uses := text(step.Get("uses"))
	with := step.Get("with")
	if repositoryWide()[job] {
		if with.Has("working_directory") || step.Has("working-directory") {
			c.emit("repository_wide", where+" scopes a repository-wide scan to the project")
		}
		return
	}
	if strings.HasPrefix(uses, "ruby/setup-ruby@") {
		c.checkRuby(where, with)
	}
	if strings.HasPrefix(uses, "actions/setup-node@") &&
		!strings.Contains(with.Get("cache-dependency-path").StrOr(""), scope) {
		c.emit("threaded", where+": actions/setup-node caches against the workspace root")
	}
	if strings.Contains(uses, "/stages/10-code-check/") && strings.Contains(uses, "javascript") &&
		!with.Get("working_directory").Is(scope) {
		c.emit("threaded", fmt.Sprintf("%s: %s is called without `working_directory`", where, stageName(uses)))
	}
	script := text(step.Get("run"))
	c.checkSonar(where, step, script)
	if script != "" && (projectCommand.MatchString(script) || strings.Contains(script, projectScript)) &&
		!step.Get("working-directory").Is(scope) {
		lines := filetext.Lines(strings.TrimSpace(script))
		c.emit("threaded", fmt.Sprintf("%s: a project command runs in the workspace root: %s",
			where, strings.TrimSpace(lines[len(lines)-1])))
	}
	c.checkReportPaths(where, step, with)
}

// stageName is the stage a `uses:` reference names: what follows its last
// `/stages/`, up to the `@`.
func stageName(uses string) string {
	if index := strings.LastIndex(uses, "/stages/"); index >= 0 {
		uses = uses[index+len("/stages/"):]
	}
	name, _, _ := strings.Cut(uses, "@")
	return name
}

func (c *checker) checkRuby(where string, with *yamldoc.Node) {
	if !with.Get("working-directory").Is(scope) {
		c.emit("threaded", where+": ruby/setup-ruby has no `working-directory`")
	}
	version := with.Get("ruby-version").StrOr("")
	for _, needle := range []string{"inputs.ruby_version", "env.RUBY_VERSION_FILE", "'3.3'"} {
		if !strings.Contains(version, needle) {
			c.emit("ruby_version", fmt.Sprintf("%s: `ruby-version` does not reference %s", where, needle))
		}
	}
	// `.tool-versions` is multi-language: asdf and mise write one for `nodejs` or
	// `python` alone, and `ruby/setup-ruby` given `default` against one with no
	// `ruby` line does not fall back -- it fails the step. Inferring `default`
	// from that filename would break a polyglot repository that passes NO input
	// at all, so the guard must never widen back to it.
	if strings.Contains(version, "tool-versions") || strings.Contains(version, "TOOL_VERSIONS") {
		c.emit("ruby_version", where+": `ruby-version` infers `default` from `.tool-versions`, which "+
			"says nothing about a `ruby` entry being in it")
	}
}

// checkSonar holds the one project-aware step that must KEEP running from the
// repository root -- `sonar.sources` is the whole repository -- while still
// being told where the project is. It decides whether coverage exists by
// globbing relative to its own working directory, and when it finds none it
// appends EMPTY `sonar.*.reportPaths` values, which override the ones the
// repository set for itself. Both halves are asserted because either alone is a
// silent no-op.
func (c *checker) checkSonar(where string, step *yamldoc.Node, script string) {
	if !strings.Contains(strings.ReplaceAll(script, `\`, "/"), sonarRunner) {
		return
	}
	if step.Has("working-directory") {
		c.emit("sonar", where+": the Sonar scan is scoped to the project, so it stops analysing the rest of "+
			"the repository")
	}
	if !step.Get("env").Get(sonarProjectDir).Is(scope) {
		c.emit("sonar", fmt.Sprintf("%s: the Sonar runner is not told where the project is (no `%s`), so a "+
			"subfolder project is read as having no coverage", where, sonarProjectDir))
	}
}

// checkReportPaths holds report paths to the project: one left root-relative
// does not fail -- it makes the step skip, so the report simply stops appearing.
func (c *checker) checkReportPaths(where string, step, with *yamldoc.Node) {
	for _, key := range reportPathKeys() {
		value := with.Get(key)
		if value.IsString() && rootRelativeReport.MatchString(value.Text()) {
			c.emit(
				"report_paths",
				fmt.Sprintf("%s: `%s: %s` is relative to the workspace root", where, key, value.Text()),
			)
		}
	}
	guard := step.Get("if").StrOr("")
	for _, literal := range []string{"hashFiles('coverage", "hashFiles('junit", "hashFiles('build"} {
		if strings.Contains(guard, literal) {
			c.emit("report_paths", where+": a hashFiles() guard names a workspace-root path")
		}
	}
}

func (c *checker) checkActions() error {
	for _, relative := range actions() {
		path := filepath.Join(c.root, relative)
		if !isFile(path) {
			c.emit("declared", relative+" is missing entirely")
			continue
		}
		document, err := yamldoc.Load(path, yamldoc.Options{})
		if err != nil {
			return fmt.Errorf("%s: %w", path, err)
		}
		c.declares(relative, document.Get("inputs").Get("working_directory"))
		for index, step := range document.Get("runs").Get("steps").Items() {
			c.checkActionStep(fmt.Sprintf("%s :: step %d", relative, index), step)
		}
	}
	return nil
}

func (c *checker) checkActionStep(where string, step *yamldoc.Node) {
	uses := text(step.Get("uses"))
	with := step.Get("with")
	if strings.HasPrefix(uses, "actions/setup-node@") &&
		!strings.Contains(with.Get("cache-dependency-path").StrOr(""), scope) {
		c.emit("threaded", where+": actions/setup-node caches against the workspace root")
	}
	if strings.HasPrefix(uses, "actions/upload-artifact@") && !strings.Contains(with.Get("path").StrOr(""), scope) {
		c.emit("report_paths", where+": the report is uploaded from the workspace root")
	}
	script := text(step.Get("run"))
	if script != "" && (projectCommand.MatchString(script) || strings.Contains(script, projectScript)) &&
		!step.Get("working-directory").Is(scope) {
		c.emit("threaded", where+": a project command runs in the workspace root")
	}
}

// checkSonarRunner holds the other half of the Sonar contract: the workflow
// exporting the variable is a no-op unless the runner reads it, and both live
// in different files.
func (c *checker) checkSonarRunner() error {
	path := filepath.Join(c.root, sonarRunner)
	if !isFile(path) {
		c.emit("sonar", sonarRunner+" is missing entirely")
		return nil
	}
	runner, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	if !strings.Contains(string(runner), sonarProjectDir) {
		c.emit(
			"sonar",
			fmt.Sprintf("%s ignores `%s`, so the workflows exporting it change nothing", sonarRunner, sonarProjectDir),
		)
	}
	return nil
}
