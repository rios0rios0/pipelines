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

// The gate script, and the analysis output both the gate and the upload read.
const (
	gateScript     = "global/scripts/tools/codeql/gate.sh"
	analysisOutput = "steps.analyze.outputs.sarif-output"
)

// actionPathReference is how the gate step reaches the script: through the
// directory the runner unpacked the action into.
var actionPathReference = regexp.MustCompile(`\$GITHUB_ACTION_PATH/([^"[:space:]]+)`)

// executableBits are the permission bits that let a script run.
const executableBits = 0o111

// composite is the parsed composite action and the positions of its four steps.
type composite struct {
	steps    []*yamldoc.Node
	init     int
	analyze  int
	upload   int
	gate     int
	findings []string
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

// checkComposite holds the GitHub CodeQL composite at `actionPath` to running
// the suite `run.sh` runs, never uploading from the analysis, gating on its
// output unconditionally, and uploading last and at best.
func checkComposite(actionPath, root string, output io.Writer) error {
	document, err := yamldoc.Load(actionPath, yamldoc.Options{})
	if err != nil {
		return err
	}
	c := &composite{steps: document.Get("runs").Get("steps").Items()}
	c.init = c.indexOf(usesAction("github/codeql-action/init@"))
	c.analyze = c.indexOf(usesAction("github/codeql-action/analyze@"))
	c.upload = c.indexOf(usesAction("github/codeql-action/upload-sarif@"))
	c.gate = c.indexOf(func(step *yamldoc.Node) bool {
		return strings.Contains(step.Get("run").StrOr(""), gateScript)
	})
	if c.init == absent || !c.steps[c.init].Get("with").Get("queries").Is("security-and-quality") {
		c.report("init does not run the security-and-quality suite run.sh runs")
	}
	c.checkAnalyze()
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
	if match := actionPathReference.FindStringSubmatch(run); match == nil {
		c.report("the gate is not reached through the action path")
	} else {
		c.checkGatePath(actionPath, root, match[1])
	}
	if c.analyze != absent && c.gate < c.analyze {
		c.report("the gate runs before the analysis")
	}
}

// checkGatePath holds the path the gate step names, from the action's own
// directory, to the gate script, and that script to being executable.
func (c *composite) checkGatePath(actionPath, root, reference string) {
	target := filepath.Join(filepath.Dir(actionPath), reference)
	if filepath.IsAbs(reference) {
		target = filepath.Clean(reference)
	}
	if target != filepath.Join(root, gateScript) {
		relative, err := filepath.Rel(root, target)
		if err != nil {
			relative = target
		}
		c.report(fmt.Sprintf("the gate path resolves to %s, not the gate script", relative))
		return
	}
	// G703: the path is the gate script the action names; checking it is the point.
	info, err := os.Stat(target) //nolint:gosec // see above
	if err != nil || info.Mode().Perm()&executableBits == 0 {
		c.report("the gate script is not executable")
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
