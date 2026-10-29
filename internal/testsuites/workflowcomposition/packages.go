package main

import (
	"fmt"
	"path/filepath"
	"regexp"
	"strings"
)

// Test 17: a deployment handed a delivered image may pull it. A job that declares `permissions:`
// gets `none` for every scope it leaves out, so a job whose step is handed a
// `needs.<job>.outputs.image` must grant `packages` (`read` or `write`, or the `read-all` /
// `write-all` shorthand); one declaring none inherits its caller's grant and is not asked.

// deliveredImage is a delivered image's output; [boundary] supplies the `\b` after it.
var deliveredImage = regexp.MustCompile(`needs\.[A-Za-z0-9_-]+\.outputs\.image`)

// grantState is what a job's `permissions:` say about pulling a package.
type grantState int

const (
	// grantInherited is a job that declares no `permissions:` and so inherits its caller's.
	grantInherited grantState = iota
	grantRefused
	grantAllowed
)

// packagesCanary is a job and the grant the classifier must read in it.
type packagesCanary struct {
	text  string
	grant grantState
}

// packagesCanaries run the classifier first, so renaming the output cannot make the scan pass by
// reading nothing.
func packagesCanaries() []packagesCanary {
	image := `"${{ !inputs.opt_out && needs.go-docker.outputs.image || '' }}"`
	steps := "steps: [{with: {image: " + image + "}}]"
	return []packagesCanary{
		{"{permissions: {contents: read}, " + steps + "}", grantRefused},
		{"{permissions: {contents: read, packages: read}, " + steps + "}", grantAllowed},
		{"{permissions: {packages: write}, " + steps + "}", grantAllowed},
		{"{permissions: read-all, " + steps + "}", grantAllowed},
		{"{permissions: {}, " + steps + "}", grantRefused},
		{"{" + steps + "}", grantInherited},
	}
}

func checkPackagesGrant(directory string, out *printer) error {
	problems := packagesCanaryProblems()
	examined := 0
	for _, name := range globFiles(directory, "*.yaml") {
		found, counted := packagesWorkflow(directory, name)
		problems = append(problems, found...)
		examined += counted
	}
	if examined == 0 {
		problems = append(problems, fmt.Sprintf("no job under %s is handed a delivered image -- the scan read nothing",
			directory))
	}
	out.line(strings.Join(problems, "\n"))
	return nil
}

// packagesCanaryProblems runs the classifier against jobs whose verdict is known.
func packagesCanaryProblems() []string {
	var problems []string
	for _, canary := range packagesCanaries() {
		job, handed, err := canaryJob(canary.text)
		if err != nil || !handed || mayPull(job) != canary.grant {
			problems = append(problems, "the classifier misreads the canary "+job.repr())
		}
	}
	tagOnly := "{steps: [{with: {version: '${{ needs.go-docker.outputs.tag_name }}'}}]}"
	if _, handed, err := canaryJob(tagOnly); err != nil || handed {
		problems = append(problems, "the classifier reads a `tag_name` output as an image")
	}
	return problems
}

// canaryJob parses a canary job and reports whether it is handed a delivered image.
func canaryJob(text string) (*value, bool, error) {
	job, err := parseDocument([]byte(text), standardYAML)
	if err != nil {
		return nil, false, err
	}
	handed, err := handedAnImage(job)
	return job, handed, err
}

// packagesWorkflow is the findings about one workflow and how many of its jobs are handed an image.
func packagesWorkflow(directory, name string) ([]string, int) {
	document, err := loadFile(filepath.Join(directory, name), standardYAML)
	if err != nil {
		return []string{fmt.Sprintf("%s: unreadable (%v)", name, err)}, 0
	}
	found, examined, err := packagesGrants(name, document)
	if err != nil {
		found = append(found, name+": "+err.Error())
	}
	return found, examined
}

// packagesGrants is a finding for every job of a workflow that is handed a delivered image without
// the grant to pull it, and how many jobs were handed one.
func packagesGrants(name string, document *value) ([]string, int, error) {
	var problems []string
	examined := 0
	err := eachJob(document, func(job string, body *value) error {
		handed, err := handedAnImage(body)
		if err != nil {
			return fmt.Errorf("job %s: %w", job, err)
		}
		if !handed {
			return nil
		}
		examined++
		if mayPull(body) == grantRefused {
			problems = append(problems, fmt.Sprintf("%s: job %s is handed a delivered image, but its `permissions:` "+
				"grant no `packages` -- add `packages: read`, or its token cannot pull a private image",
				name, job))
		}
		return nil
	})
	return problems, examined, err
}

// handedAnImage reports whether a step of the job is handed a `needs.<job>.outputs.image`.
func handedAnImage(job *value) (bool, error) {
	steps, err := sequenceOr(job.get("steps"), "steps")
	if err != nil {
		return false, err
	}
	for index, item := range steps.items {
		if !item.is(mappingKind) {
			return false, fmt.Errorf("step %d is %s, not a mapping", index+1, item.describe())
		}
		var inputs *value
		if inputs, err = mappingOr(item.get("with"), fmt.Sprintf("the with: of step %d", index+1)); err != nil {
			return false, err
		}
		for _, input := range inputs.pairs {
			if mentionsDeliveredImage(input.value.str()) {
				return true, nil
			}
		}
	}
	return false, nil
}

// mentionsDeliveredImage reports whether `text` reads a delivered image's output as a whole word.
func mentionsDeliveredImage(text string) bool {
	for _, match := range deliveredImage.FindAllStringIndex(text, -1) {
		if boundary(text, match[1]) {
			return true
		}
	}
	return false
}

// mayPull is what a job's `permissions:` grant for pulling a package.
func mayPull(job *value) grantState {
	if !job.has("permissions") {
		return grantInherited
	}
	grant := job.get("permissions")
	switch {
	case grant.is(stringKind):
		if grant.text == "read-all" || grant.text == "write-all" {
			return grantAllowed
		}
	case grant.is(mappingKind):
		packages := "none"
		if grant.has("packages") {
			packages = grant.get("packages").str()
		}
		if packages == "read" || packages == "write" {
			return grantAllowed
		}
	}
	return grantRefused
}
