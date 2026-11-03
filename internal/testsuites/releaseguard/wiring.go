package main

import (
	"fmt"
	"path/filepath"
	"slices"
	"strconv"
	"strings"

	"github.com/rios0rios0/pipelines/internal/testsuites/yamldoc"
)

// The deployment stage's actions, by the directory each lives in. A step using any other action
// under the stage is a deployment.
const (
	deploymentStage = "rios0rios0/pipelines/github/global/stages/50-deployment/"
	guardAction     = "release-guard"
	gateAction      = "require-checks"
	rollbackInput   = "allow_rollback"
)

// guardedOutput is the only `deploy` output the guard job may hand on, for the step id it names. On
// a branch run the guard runs no step, so the job answers `true`; on a tag run it hands on the step's
// verdict and nothing else, so a step that wrote none leaves `deploy` empty and the deployment
// skipped. `steps.<id>.outputs.deploy || 'true'` reads the same and deploys whatever the step did.
func guardedOutput(step string) string {
	return "${{ github.ref_type != 'tag' && 'true' || steps." + step + ".outputs.deploy }}"
}

// gateConjunct is the term every clause of a deployment job's `if:` must carry for the guard job
// `guard`.
func gateConjunct(guard string) string {
	return "needs." + guard + ".outputs.deploy == 'true'"
}

// wiring is every finding about the workflows in the directory, after any about the canaries.
func wiring(directory string) ([]string, error) {
	findings := canaryFindings()
	paths, err := filepath.Glob(filepath.Join(directory, "*.yaml"))
	if err != nil {
		return nil, err
	}
	deployments := 0
	for _, path := range paths {
		name := filepath.Base(path)
		document, loadErr := yamldoc.Load(path, yamldoc.Options{})
		if loadErr != nil {
			findings = append(findings, fmt.Sprintf("%s: unreadable (%v)", name, loadErr))
			continue
		}
		found, deploying := workflowFindings(name, document)
		findings = append(findings, found...)
		deployments += deploying
	}
	if deployments == 0 {
		findings = append(findings, "no workflow in "+directory+
			" deploys through a 50-deployment provider -- the scan read nothing")
	}
	return findings, nil
}

// workflowFindings are the findings about one workflow, and how many of its jobs deploy.
func workflowFindings(name string, document *yamldoc.Node) ([]string, int) {
	var guards []string
	var deployers []yamldoc.Pair
	for _, job := range document.Get("jobs").Pairs() {
		switch {
		case stepUsing(job.Value, guardAction) != nil:
			guards = append(guards, job.Key.Str())
		case deploys(job.Value):
			deployers = append(deployers, job)
		}
	}
	if len(deployers) == 0 {
		return nil, 0
	}
	if len(guards) != 1 {
		return []string{fmt.Sprintf("%s: %d jobs run 50-deployment/%s, not exactly one, so its deployment "+
			"is not gated on the release guard", name, len(guards), guardAction)}, len(deployers)
	}
	guard := guards[0]
	findings := guardFindings(name, guard, document.Get("jobs").Get(guard))
	findings = append(findings, inputFindings(name, document)...)
	for _, job := range deployers {
		findings = append(findings, deployerFindings(name, job.Key.Str(), job.Value, guard)...)
	}
	return findings, len(deployers)
}

// guardFindings hold the guard job to what makes a refusal a skipped deployment: no environment of
// its own, the rollback input passed through, and its step's verdict handed on unchanged.
func guardFindings(name, id string, job *yamldoc.Node) []string {
	var findings []string
	if job.Has("environment") {
		findings = append(findings, fmt.Sprintf("%s: job %s declares `environment:`, so a refused tag still "+
			"enters it -- its approvals and its deployment record included", name, id))
	}
	step := stepUsing(job, guardAction)
	if passed := step.Get("with").Get(rollbackInput).StrOr(""); passed != "${{ inputs."+rollbackInput+" }}" {
		findings = append(findings, fmt.Sprintf("%s: job %s hands the guard %s %s, not the workflow's own "+
			"input", name, id, rollbackInput, strconv.Quote(passed)))
	}
	stepID := step.Get("id").StrOr("")
	if output := job.Get("outputs").Get("deploy").StrOr(""); stepID == "" || output != guardedOutput(stepID) {
		findings = append(findings, fmt.Sprintf("%s: job %s outputs deploy %s, not %s", name, id,
			strconv.Quote(output), strconv.Quote(guardedOutput(stepID))))
	}
	return findings
}

// inputFindings hold the rollback input to a boolean that is off unless a caller turns it on.
func inputFindings(name string, document *yamldoc.Node) []string {
	input := document.Get("on").Get("workflow_call").Get("inputs").Get(rollbackInput)
	defaults := input.Get("default")
	if input.Get("type").Is("boolean") && defaults.Kind() == yamldoc.Bool && defaults.IsFalseOrNull() {
		return nil
	}
	return []string{fmt.Sprintf("%s: no `%s` input that is a boolean defaulting to false", name, rollbackInput)}
}

// deployerFindings hold a deployment job to waiting for the guard and deploying only on its yes.
func deployerFindings(name, id string, job *yamldoc.Node, guard string) []string {
	var findings []string
	if !slices.Contains(needs(job), guard) {
		findings = append(findings, fmt.Sprintf("%s: job %s does not need %s, so it cannot read its verdict",
			name, id, guard))
	}
	condition := job.Get("if").StrOr("")
	for _, clause := range split(unwrap(condition), "||") {
		if !slices.Contains(split(clause, "&&"), gateConjunct(guard)) {
			findings = append(findings, fmt.Sprintf("%s: job %s deploys when %s holds, with no `%s` beside it",
				name, id, strconv.Quote(clause), gateConjunct(guard)))
		}
	}
	return findings
}

// stepUsing is the job's first step using the deployment stage's `action`, or nil.
func stepUsing(job *yamldoc.Node, action string) *yamldoc.Node {
	for _, step := range job.Get("steps").Items() {
		if strings.HasPrefix(step.Get("uses").StrOr(""), deploymentStage+action+"@") {
			return step
		}
	}
	return nil
}

// deploys reports whether one of the job's steps deploys: it uses a deployment-stage action that is
// neither of the two gates.
func deploys(job *yamldoc.Node) bool {
	for _, step := range job.Get("steps").Items() {
		action, found := strings.CutPrefix(step.Get("uses").StrOr(""), deploymentStage)
		if !found {
			continue
		}
		action, _, _ = strings.Cut(action, "@")
		if action != guardAction && action != gateAction {
			return true
		}
	}
	return false
}

// needs is a job's `needs:`, which GitHub accepts as one job id or a list of them.
func needs(job *yamldoc.Node) []string {
	listed := job.Get("needs")
	if listed.IsString() {
		return []string{listed.Text()}
	}
	var ids []string
	for _, item := range listed.Items() {
		ids = append(ids, item.Str())
	}
	return ids
}

// unwrap is an expression without the `${{ }}` an `if:` may wrap it in.
func unwrap(expression string) string {
	trimmed := strings.TrimSpace(expression)
	if inner, found := strings.CutPrefix(trimmed, "${{"); found {
		if inner, found = strings.CutSuffix(inner, "}}"); found {
			return inner
		}
	}
	return trimmed
}

// split cuts an expression at every `operator` outside parentheses and quoted strings, and returns
// the operands with their surrounding blanks and redundant outer parentheses removed and every run
// of blanks inside folded to one space, so a reformatted expression compares equal to its original.
func split(expression, operator string) []string {
	var operands []string
	depth, quoted, start := 0, false, 0
	for index := 0; index < len(expression); index++ {
		switch character := expression[index]; {
		case character == '\'':
			quoted = !quoted
		case quoted:
		case character == '(':
			depth++
		case character == ')':
			depth--
		case depth == 0 && strings.HasPrefix(expression[index:], operator):
			operands = append(operands, operand(expression[start:index]))
			index += len(operator) - 1
			start = index + 1
		}
	}
	return append(operands, operand(expression[start:]))
}

// operand is one operand of a split expression, normalized as split describes.
func operand(text string) string {
	folded := strings.Join(strings.Fields(text), " ")
	for strings.HasPrefix(folded, "(") && strings.HasSuffix(folded, ")") && enclosed(folded) {
		folded = strings.TrimSpace(folded[1 : len(folded)-1])
	}
	return folded
}

// enclosed reports whether the parenthesis opening `text` is the one closing it, so that removing
// the pair cannot join two groups: `(a) || (b)` starts and ends with one, and is not enclosed.
func enclosed(text string) bool {
	depth, quoted := 0, false
	for index := range len(text) {
		switch character := text[index]; {
		case character == '\'':
			quoted = !quoted
		case quoted:
		case character == '(':
			depth++
		case character == ')':
			depth--
			if depth == 0 && index < len(text)-1 {
				return false
			}
		}
	}
	return depth == 0
}
