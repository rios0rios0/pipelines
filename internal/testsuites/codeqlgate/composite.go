package main

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strings"

	"github.com/rios0rios0/pipelines/internal/testsuites/yamldoc"
)

// The scripts the composite runs, and the analysis output the extraction check,
// the gate and the upload read.
const (
	gateScript       = "global/scripts/tools/codeql/gate.sh"
	extractionScript = "global/scripts/tools/codeql/extraction.sh"
	workspaceHelper  = "global/scripts/tools/codeql/go-workspace.sh"
	analysisOutput   = "steps.analyze.outputs.sarif-output"
)

// actionPathReference is how a step reaches a script: through the directory
// the runner unpacked the action into.
var actionPathReference = regexp.MustCompile(`\$GITHUB_ACTION_PATH/([^"[:space:]]+)`)

// executableBits are the permission bits that let a script run.
const executableBits = 0o111

// composite is the parsed composite action and the positions of its six steps.
type composite struct {
	steps       []*yamldoc.Node
	init        int
	goWorkspace int
	analyze     int
	extraction  int
	upload      int
	gate        int
	findings    []string
}

// absent is the position of a step the composite does not have.
const absent = -1

func (c *composite) report(finding string) {
	c.findings = append(c.findings, finding)
}

func (c *composite) indexOf(found func(*yamldoc.Node) bool) int {
	for index, step := range c.steps {
		if found(step) {
			return index
		}
	}
	return absent
}

func usesAction(prefix string) func(*yamldoc.Node) bool {
	return func(step *yamldoc.Node) bool {
		return strings.HasPrefix(step.Get("uses").StrOr(""), prefix)
	}
}

func runsScript(script string) func(*yamldoc.Node) bool {
	return func(step *yamldoc.Node) bool {
		return strings.Contains(step.Get("run").StrOr(""), script)
	}
}

// checkComposite holds the GitHub CodeQL composite at `actionPath` to running
// the suite `run.sh` runs, building Go in the repository's own workspace,
// never uploading from the analysis, failing an analysis that read no code,
// gating on its output unconditionally, and uploading last and at best.
func checkComposite(actionPath, root string, output io.Writer) error {
	document, err := yamldoc.Load(actionPath, yamldoc.Options{})
	if err != nil {
		return err
	}
	c := &composite{steps: document.Get("runs").Get("steps").Items()}
	c.init = c.indexOf(usesAction("github/codeql-action/init@"))
	c.goWorkspace = c.indexOf(runsScript(workspaceHelper))
	c.analyze = c.indexOf(usesAction("github/codeql-action/analyze@"))
	c.extraction = c.indexOf(runsScript(extractionScript))
	c.upload = c.indexOf(usesAction("github/codeql-action/upload-sarif@"))
	c.gate = c.indexOf(runsScript(gateScript))
	if c.init == absent || !c.steps[c.init].Get("with").Get("queries").Is("security-and-quality") {
		c.report("init does not run the security-and-quality suite run.sh runs")
	}
	c.checkGoWorkspace(actionPath, root)
	c.checkAnalyze()
	c.checkExtraction(actionPath, root)
	c.checkGate(actionPath, root)
	c.checkUpload()
	for index, step := range c.steps {
		if step.Get("continue-on-error").Truthy() && index != c.upload {
			c.report(
				fmt.Sprintf("step %d (%s) is continue-on-error; only the upload may be", index, step.Get("name").Str()),
			)
		}
	}
	for _, finding := range c.findings {
		if _, err = fmt.Fprintln(output, finding); err != nil {
			return err
		}
	}
	return nil
}

func (c *composite) checkAnalyze() {
	if c.analyze == absent {
		c.report("no analyze step")
		return
	}
	step := c.steps[c.analyze]
	if !step.Get("id").Is("analyze") {
		c.report("the analyze step is not id 'analyze', which the gate and the upload read")
	}
	if !step.Get("with").Get("upload").Is("never") {
		c.report("analyze uploads, so code scanning being unavailable can fail the analysis step")
	}
}

func (c *composite) checkGate(actionPath, root string) {
	if c.gate == absent {
		c.report("no step runs the gate")
		return
	}
	step := c.steps[c.gate]
	run := step.Get("run").StrOr("")
	if step.Has("if") {
		c.report("the gate step carries an if:, so something can skip it")
	}
	if step.Get("continue-on-error").Truthy() {
		c.report("the gate step is continue-on-error, so a finding fails nothing")
	}
	if !strings.Contains(step.Get("env").StrOr("")+run, analysisOutput) {
		c.report("the gate does not read the analysis output")
	}
	c.checkScriptPath(actionPath, root, run, script{gateScript, "the gate", "the gate script", true})
	if c.analyze != absent && c.gate < c.analyze {
		c.report("the gate runs before the analysis")
	}
}

// checkGoWorkspace holds the step that keeps a Go build in the repository's
// own workspace to running for a Go analysis alone and before `init`, so the
// autobuild runs under the GOWORK it decides; to sourcing the helper `run.sh`
// sources, through the action path; and to handing GOWORK to the later steps.
func (c *composite) checkGoWorkspace(actionPath, root string) {
	if c.goWorkspace == absent {
		c.report("no step keeps the Go build in the repository's own workspace")
		return
	}
	step := c.steps[c.goWorkspace]
	run := step.Get("run").StrOr("")
	if !strings.Contains(step.Get("if").StrOr(""), "inputs.codeql_language == 'go'") {
		c.report("the Go workspace step does not run for a Go analysis alone")
	}
	if !strings.Contains(run, "GITHUB_ENV") {
		c.report("the Go workspace step does not hand GOWORK to the later steps through GITHUB_ENV")
	}
	c.checkScriptPath(actionPath, root, run,
		script{workspaceHelper, "the Go workspace step", "the Go workspace helper", false})
	if c.init != absent && c.goWorkspace > c.init {
		c.report("the Go workspace step runs after init, so the autobuild never sees its GOWORK")
	}
}

// checkExtraction holds the step that fails an analysis which read no code to
// running whenever the analysis succeeded, after it and before the gate -- the
// gate passes an analysis of nothing as clean -- over the analysis output,
// through the action path, and leniently: --strict fails a language without a
// lines-of-code metric, such as this repository's own `actions`.
func (c *composite) checkExtraction(actionPath, root string) {
	if c.extraction == absent {
		c.report("no step checks that the analysis read code")
		return
	}
	step := c.steps[c.extraction]
	run := step.Get("run").StrOr("")
	if step.Has("if") {
		c.report("the extraction check carries an if:, so something can skip it")
	}
	if !strings.Contains(step.Get("env").StrOr("")+run, analysisOutput) {
		c.report("the extraction check does not read the analysis output")
	}
	if strings.Contains(run, "--strict") {
		c.report("the extraction check is strict, so a language without a lines-of-code metric fails")
	}
	c.checkScriptPath(actionPath, root, run,
		script{extractionScript, "the extraction check", "the extraction script", true})
	if c.analyze != absent && c.extraction < c.analyze {
		c.report("the extraction check runs before the analysis")
	}
	if c.gate != absent && c.extraction > c.gate {
		c.report("the extraction check runs after the gate, which has passed an analysis of nothing by then")
	}
}

// script is what a step's `run` must reach through the action path: the path
// from the repository root, how the findings name the step and the script, and
// whether the step runs it (it must be executable) or sources it.
type script struct {
	path       string
	step       string
	name       string
	executable bool
}

// checkScriptPath holds the path `run` reaches through the action path, from
// the action's own directory, to `want.path`, and that script to existing --
// and to being executable, when the step runs it.
func (c *composite) checkScriptPath(actionPath, root, run string, want script) {
	match := actionPathReference.FindStringSubmatch(run)
	if match == nil {
		c.report(want.step + " is not reached through the action path")
		return
	}
	reference := match[1]
	target := filepath.Join(filepath.Dir(actionPath), reference)
	if filepath.IsAbs(reference) {
		target = filepath.Clean(reference)
	}
	if target != filepath.Join(root, want.path) {
		relative, err := filepath.Rel(root, target)
		if err != nil {
			relative = target
		}
		c.report(fmt.Sprintf("%s path resolves to %s, not %s", want.step, relative, want.name))
		return
	}
	// G703: the path is the script the action names; checking it is the point.
	info, err := os.Stat(target) //nolint:gosec // see above
	switch {
	case want.executable && (err != nil || info.Mode().Perm()&executableBits == 0):
		c.report(want.name + " is not executable")
	case err != nil:
		c.report(want.name + " does not exist")
	}
}

func (c *composite) checkUpload() {
	if c.upload == absent {
		c.report("no upload-sarif step")
		return
	}
	step := c.steps[c.upload]
	condition := step.Get("if").StrOr("")
	if !step.Get("continue-on-error").IsTrue() {
		c.report("the upload step is not continue-on-error, so a refused upload fails the job")
	}
	if !strings.Contains(condition, "always()") {
		c.report("the upload step does not run after a failed gate")
	}
	if !strings.Contains(condition, "inputs.upload") {
		c.report("the upload step ignores the upload input")
	}
	if c.gate != absent && c.upload < c.gate {
		c.report("the upload runs before the gate has decided")
	}
	if !strings.Contains(step.Get("with").Get("sarif_file").StrOr(""), analysisOutput) {
		c.report("the upload does not publish the analysis output")
	}
}
