package main

import (
	"os"
	"path/filepath"
	"slices"
	"strings"
)

// globFiles is the base names of the directory's entries that `pattern` matches, in code-point
// order -- `sorted(glob.glob(os.path.join(directory, pattern)))` as the checks first read it. A dot
// file is never matched, as glob's `*` never matched one, and a directory that cannot be listed has
// no entries, as glob found none in it.
func globFiles(directory, pattern string) []string {
	entries, err := os.ReadDir(directory)
	if err != nil {
		return nil
	}
	var names []string
	for _, entry := range entries {
		name := entry.Name()
		if strings.HasPrefix(name, ".") {
			continue
		}
		if matched, _ := filepath.Match(pattern, name); matched {
			names = append(names, name)
		}
	}
	return names
}

// root is the document as the mapping a workflow is; an empty file is an empty mapping.
func root(document *value) (*value, error) {
	return mappingOr(document, "the document")
}

// trigger is the workflow's `on:` value as written: a mapping of events, an event name, a list of
// event names, or nothing.
func trigger(document *value) (*value, error) {
	workflow, err := root(document)
	if err != nil {
		return nil, err
	}
	return workflow.get("on"), nil
}

// triggerEvents is the `on:` block as the mapping of each event to its configuration. An event
// written by name alone -- `on: push`, `on: [push, workflow_call]` -- is configured with nothing,
// so it contributes no entry.
func triggerEvents(document *value) (*value, error) {
	events, err := trigger(document)
	if err != nil {
		return nil, err
	}
	if events.is(stringKind) || events.is(sequenceKind) {
		return &value{kind: mappingKind}, nil
	}
	return mappingOr(events, "on")
}

// triggers reports whether the workflow runs on `event`, however its `on:` names it.
func triggers(document *value, event string) (bool, error) {
	events, err := trigger(document)
	if err != nil {
		return false, err
	}
	switch {
	case events.is(stringKind):
		return events.text == event, nil
	case events.is(sequenceKind):
		return slices.ContainsFunc(events.items, func(item *value) bool { return item.isString(event) }), nil
	default:
		if events, err = mappingOr(events, "on"); err != nil {
			return false, err
		}
		return events.has(event), nil
	}
}

// declaredInputs is `on.workflow_call.inputs`: the inputs a reusable workflow declares, or an empty
// mapping for a workflow that declares none.
func declaredInputs(document *value) (*value, error) {
	events, err := triggerEvents(document)
	if err != nil {
		return nil, err
	}
	call, err := mappingOr(events.get("workflow_call"), "on.workflow_call")
	if err != nil {
		return nil, err
	}
	return mappingOr(call.get("inputs"), "on.workflow_call.inputs")
}

// jobsOf is the workflow's `jobs:` mapping.
func jobsOf(document *value) (*value, error) {
	workflow, err := root(document)
	if err != nil {
		return nil, err
	}
	return mappingOr(workflow.get("jobs"), "jobs")
}

// jobBody is one job's mapping: `job or {}`, which a job written as anything else cannot be.
func jobBody(job pair) (*value, error) {
	return mappingOr(job.value, "job "+job.key.str())
}

// eachJob calls `visit` with the name and body of every job, in document order, and stops at the
// first job it cannot read or the first error `visit` returns.
func eachJob(document *value, visit func(name string, body *value) error) error {
	workflowJobs, err := jobsOf(document)
	if err != nil {
		return err
	}
	for _, job := range workflowJobs.pairs {
		var body *value
		if body, err = jobBody(job); err != nil {
			return err
		}
		if err = visit(job.key.str(), body); err != nil {
			return err
		}
	}
	return nil
}
