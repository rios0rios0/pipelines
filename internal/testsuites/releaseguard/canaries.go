package main

import (
	"fmt"
	"strings"

	"github.com/rios0rios0/pipelines/internal/testsuites/yamldoc"
)

// canary is a workflow and the number of findings the check must report about it.
type canary struct {
	name     string
	text     string
	findings int
}

// guardedWorkflow is a deployment workflow wired the way every one here must be. The deployment
// job's `if:` is supplied by each canary.
func guardedWorkflow(condition string) string {
	return strings.Join([]string{
		"on:",
		"  workflow_call:",
		"    inputs:",
		"      allow_rollback: { type: 'boolean', required: false, default: false }",
		"jobs:",
		"  base: { uses: 'rios0rios0/pipelines/.github/workflows/go-docker.yaml@main' }",
		"  deployment-release-guard:",
		"    name: 'deployment > release-guard'",
		"    outputs:",
		"      deploy: \"" + guardedOutput("guard") + "\"",
		"    steps:",
		"      - id: 'guard'",
		"        uses: '" + deploymentStage + guardAction + "@main'",
		"        with: { allow_rollback: '${{ inputs.allow_rollback }}' }",
		"    needs: [ 'base' ]",
		"  deployment-flyio:",
		"    environment: 'production'",
		"    steps:",
		"      - uses: '" + deploymentStage + gateAction + "@main'",
		"      - uses: '" + deploymentStage + "flyio@main'",
		"    needs: [ 'base', 'deployment-release-guard' ]",
		"    if: \"" + condition + "\"",
		"",
	}, "\n")
}

// canaries run the check first, so a parser that stops reading the wiring fails here instead of
// passing with nothing flagged.
func canaries() []canary {
	gate := gateConjunct("deployment-release-guard")
	guarded := guardedWorkflow("!cancelled() && " + gate + " && (a || b)")
	return []canary{
		{"wired", guarded, 0},
		{"wired, the gate in parentheses and spread over blanks",
			guardedWorkflow("${{ (!cancelled()) &&   (" + gate + ") }}"), 0},
		{"no guard job", strings.Replace(guarded, deploymentStage+guardAction+"@main", "actions/checkout@v7", 1), 1},
		{"the gate in one clause of two", guardedWorkflow("(" + gate + " && a) || b"), 1},
		{"no gate at all", guardedWorkflow("!cancelled()"), 1},
		{"the guard not needed",
			strings.Replace(guarded, "[ 'base', 'deployment-release-guard' ]", "[ 'base' ]", 1), 1},
		{"a fail-open output", strings.Replace(guarded, guardedOutput("guard"),
			"${{ steps.guard.outputs.deploy || 'true' }}", 1), 1},
		{"the guard in an environment", strings.Replace(guarded, "    name: 'deployment > release-guard'",
			"    name: 'deployment > release-guard'\n    environment: 'production'", 1), 1},
		{"a rollback on by default", strings.Replace(guarded, "default: false", "default: true", 1), 1},
		{"a constant rollback", strings.Replace(guarded, "'${{ inputs.allow_rollback }}'", "'true'", 1), 1},
	}
}

// canaryFindings are a finding for every canary the check misjudges, and nothing when it judges them
// all as it must.
func canaryFindings() []string {
	var findings []string
	for _, sample := range canaries() {
		document, err := yamldoc.Parse([]byte(sample.text), yamldoc.Options{})
		if err != nil {
			findings = append(findings, fmt.Sprintf("canary %q does not parse: %v", sample.name, err))
			continue
		}
		found, _ := workflowFindings("canary", document)
		if len(found) != sample.findings {
			findings = append(findings, fmt.Sprintf("the check reports %d finding(s) about canary %q, not %d: %s",
				len(found), sample.name, sample.findings, strings.Join(found, "; ")))
		}
	}
	return findings
}
