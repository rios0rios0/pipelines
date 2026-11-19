package main

import (
	"fmt"
	"io"
	"path/filepath"
	"regexp"
	"slices"
	"strings"

	"github.com/rios0rios0/pipelines/internal/testsuites/yamldoc"
)

// samBuild and samPackage are a script line that runs `sam build` or `sam package`.
var (
	samBuild   = regexp.MustCompile(`(?m)^[[:space:]]*sam[[:space:]]+build\b`)
	samPackage = regexp.MustCompile(`(?m)^[[:space:]]*sam[[:space:]]+package\b`)
)

// awsTaskPrefix starts the `task` of a step that holds the service connection's
// credentials for as long as it runs.
const awsTaskPrefix = "AWSShellScript@"

// regionVariables are the variables `AWSShellScript` sets from its `regionName`.
func regionVariables() []string {
	return []string{"AWS_REGION", "AWS_DEFAULT_REGION"}
}

// pipelineStep is one step of a job, with the script it runs.
type pipelineStep struct {
	name    string
	node    *yamldoc.Node
	script  string
	awsTask bool
}

// checkCredentials holds the SAM delivery to building where no AWS credentials are
// held. `AWSShellScript` takes the service connection's credentials as it starts, and
// an assumed role's last 15 minutes by default, so a build inside that step can leave
// the packaging after it holding expired ones. `sam build` therefore runs in a plain
// step of its own, before every step that runs `sam package`, with the region the AWS
// task packages in, and none of those steps runs after a failed one.
func checkCredentials(root string, output io.Writer) error {
	file := deliveryTemplate()
	document, err := yamldoc.Load(filepath.Join(root, file.path), yamldoc.Options{})
	if err != nil {
		return fmt.Errorf("%s: %w", file.path, err)
	}
	var problems []string
	found := false
	for _, steps := range jobSteps(document) {
		if !runs(steps, samBuild) && !runs(steps, samPackage) {
			continue
		}
		found = true
		problems = append(problems, buildProblems(file.name, steps)...)
	}
	if !found {
		problems = append(problems, file.name+": no step runs `sam build`")
	}
	if err = report(output, file.name, problems); err != nil {
		return err
	}
	return conclude(output, "\nErrors found:", problems)
}

// jobSteps are the steps of every job the document declares, one list per job.
func jobSteps(document *yamldoc.Node) [][]pipelineStep {
	var jobs [][]pipelineStep
	for _, stage := range document.Get("stages").Items() {
		for _, job := range stage.Get("jobs").Items() {
			var steps []pipelineStep
			for index, step := range job.Get("steps").Items() {
				steps = append(steps, pipelineStep{
					name:    step.Get("displayName").StrOr(fmt.Sprintf("step %d", index+1)),
					node:    step,
					script:  stepScript(step),
					awsTask: strings.HasPrefix(step.Get("task").Text(), awsTaskPrefix),
				})
			}
			jobs = append(jobs, steps)
		}
	}
	return jobs
}

// stepScript is what a step runs: a `script` or `bash` step's body, or a task's
// inline script.
func stepScript(step *yamldoc.Node) string {
	for _, key := range []string{"script", "bash"} {
		if step.Has(key) {
			return step.Get(key).Text()
		}
	}
	return step.Get("inputs").Get("inlineScript").Text()
}

// runs reports whether any of the steps runs the command.
func runs(steps []pipelineStep, command *regexp.Regexp) bool {
	return slices.ContainsFunc(steps, func(step pipelineStep) bool {
		return command.MatchString(step.script)
	})
}

// buildProblems are what keeps one job from building before, and apart from, the
// steps that hold its credentials.
func buildProblems(name string, steps []pipelineStep) []string {
	var problems []string
	build := -1
	for index, step := range steps {
		if !samBuild.MatchString(step.script) {
			continue
		}
		if build >= 0 {
			problems = append(problems, fmt.Sprintf("%s: '%s' runs `sam build` a second time", name, step.name))
			continue
		}
		build = index
	}
	if build < 0 {
		return append(problems, name+": no step runs `sam build`")
	}
	problems = append(problems, builderProblems(name, steps[build])...)
	return append(problems, packagingProblems(name, steps, build)...)
}

// builderProblems are what has the step running `sam build` hold credentials, or
// run after a failed step.
func builderProblems(name string, builder pipelineStep) []string {
	var problems []string
	if builder.awsTask {
		problems = append(problems, fmt.Sprintf("%s: '%s' runs `sam build` in an AWSShellScript task, "+
			"holding the service connection's credentials while it builds", name, builder.name))
	}
	if samPackage.MatchString(builder.script) {
		problems = append(problems, fmt.Sprintf("%s: '%s' runs `sam build` and `sam package` in one step",
			name, builder.name))
	}
	if !waitsForSuccess(builder.node) {
		problems = append(problems, conditionProblem(name, builder))
	}
	return problems
}

// packagingProblems are what lets a step running `sam package` start before the
// build or after a failed one, or package in a region the build did not have.
func packagingProblems(name string, steps []pipelineStep, build int) []string {
	builder := steps[build]
	var problems []string
	packaged := samPackage.MatchString(builder.script)
	for index, step := range steps {
		if index == build || !samPackage.MatchString(step.script) {
			continue
		}
		packaged = true
		if index < build {
			problems = append(problems, fmt.Sprintf("%s: '%s' runs `sam package` before '%s' builds",
				name, step.name, builder.name))
		}
		if !waitsForSuccess(step.node) {
			problems = append(problems, conditionProblem(name, step))
		}
		problems = append(problems, regionProblems(name, builder, step)...)
	}
	if !packaged {
		problems = append(problems, name+": no step runs `sam package`")
	}
	return problems
}

// regionProblems are the region variables a plain build step does not set to the
// region an AWS packaging task runs in. Inside that task, the build had them from it.
func regionProblems(name string, builder, packaging pipelineStep) []string {
	region := packaging.node.Get("inputs").Get("regionName").Text()
	if builder.awsTask || !packaging.awsTask || region == "" {
		return nil
	}
	var problems []string
	for _, variable := range regionVariables() {
		if builder.node.Get("env").Get(variable).Text() != region {
			problems = append(problems, fmt.Sprintf("%s: '%s' does not set %s to %s, the region '%s' packages in",
				name, builder.name, variable, region, packaging.name))
		}
	}
	return problems
}

// waitsForSuccess reports whether a step runs only once the steps before it
// succeeded. A condition of its own replaces the default `succeeded()` rather than
// adding to it, so a step that declares one must call `succeeded()` itself.
func waitsForSuccess(step *yamldoc.Node) bool {
	return !step.Has("condition") || strings.Contains(step.Get("condition").Str(), "succeeded()")
}

// conditionProblem is a step whose condition lets it run after a failed step.
func conditionProblem(name string, step pipelineStep) string {
	return fmt.Sprintf("%s: '%s' has a condition without `succeeded()`, so it runs after a failed step",
		name, step.name)
}
