package main

import (
	"fmt"
	"io"
	"path/filepath"
	"strings"

	"github.com/rios0rios0/pipelines/internal/testsuites/yamldoc"
)

// steps are every step of every job in a workflow, in document order.
func steps(document *yamldoc.Node) []*yamldoc.Node {
	var found []*yamldoc.Node
	for _, job := range document.Get("jobs").Pairs() {
		found = append(found, job.Value.Get("steps").Items()...)
	}
	return found
}

// requireChecksNeeds lists what each step running the require-checks gate hands
// it as `needs`, so a deployment workflow added later is guarded because it is
// iterated, not because somebody remembered to list it.
func requireChecksNeeds(workflows []string, output io.Writer) error {
	for _, path := range workflows {
		document, err := yamldoc.Load(path, yamldoc.Options{})
		if err != nil {
			return fmt.Errorf("%s: %w", path, err)
		}
		for _, step := range steps(document) {
			if !strings.Contains(step.Get("uses").StrOr(""), "50-deployment/require-checks@") {
				continue
			}
			needs := step.Get("with").Get("needs").StrOr("")
			if _, err = fmt.Fprintf(output, "%s\t%s\n", filepath.Base(path), needs); err != nil {
				return err
			}
		}
	}
	return nil
}

// secretsStep writes the script of the first step gated on BUILD_ENV_SECRETS,
// or says that there is none -- a sentence that fails every assertion run on
// it by name rather than one that passes against nothing.
func secretsStep(path string, output io.Writer) error {
	document, err := yamldoc.Load(path, yamldoc.Options{})
	if err != nil {
		return fmt.Errorf("%s: %w", path, err)
	}
	for _, step := range steps(document) {
		if strings.Contains(step.Get("if").StrOr(""), "BUILD_ENV_SECRETS") {
			_, err = io.WriteString(output, step.Get("run").StrOr(""))
			return err
		}
	}
	_, err = fmt.Fprintln(output, "no step gated on BUILD_ENV_SECRETS was found")
	return err
}

// inputOff holds a reusable workflow's input to being a boolean whose default
// is off.
func inputOff(path, name string) error {
	document, err := yamldoc.Load(path, yamldoc.Options{})
	if err != nil {
		return fmt.Errorf("%s: %w", path, err)
	}
	input := document.Get("on").Get("workflow_call").Get("inputs").Get(name)
	defaults := input.Get("default")
	if !input.Get("type").Is("boolean") || defaults.Kind() == yamldoc.Null || !defaults.IsFalseOrNull() {
		return errFailed
	}
	return nil
}
