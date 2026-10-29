package main

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"unicode/utf8"

	"github.com/rios0rios0/pipelines/internal/testsuites/yamldoc"
)

// parameterReference is a template expression reading one parameter.
var parameterReference = regexp.MustCompile(`\$\{\{[[:space:]]*parameters\.(\w+)[[:space:]]*\}\}`)

// template is a file under check and the name its lines report it by.
type template struct {
	name string
	path string
}

// mainTemplates are the entry templates a consumer extends.
func mainTemplates() []template {
	return []template{
		{name: "go-lambda.yaml", path: "azure-devops/golang/go-lambda.yaml"},
		{name: "go-lambda-sam.yaml", path: "azure-devops/golang/go-lambda-sam.yaml"},
	}
}

// stageTemplates are the stages those entry templates include.
func stageTemplates() []template {
	return []template{
		{name: "delivery/lambda.yaml", path: "azure-devops/golang/stages/40-delivery/lambda.yaml"},
		{name: "deployment/lambda.yaml", path: "azure-devops/golang/stages/50-deployment/lambda.yaml"},
	}
}

func writeLines(output io.Writer, lines ...string) error {
	for _, line := range lines {
		if _, err := fmt.Fprintln(output, line); err != nil {
			return err
		}
	}
	return nil
}

// checkSyntax holds every Lambda template to parsing.
func checkSyntax(root string, output io.Writer) error {
	failed := false
	for _, file := range append(mainTemplates(), stageTemplates()...) {
		line := "  ✓ " + file.path
		if _, err := yamldoc.Load(filepath.Join(root, file.path), yamldoc.Options{}); err != nil {
			line = fmt.Sprintf("  ✗ %s: %v", file.path, err)
			failed = true
		}
		if err := writeLines(output, line); err != nil {
			return err
		}
	}
	if failed {
		return errFailed
	}
	return nil
}

// checkStructure holds the main templates to their `stages` and `parameters`,
// and every stage template to at least one of them.
func checkStructure(root string, output io.Writer) error {
	var problems []string
	for _, file := range mainTemplates() {
		document, err := yamldoc.Load(filepath.Join(root, file.path), yamldoc.Options{})
		if err != nil {
			return fmt.Errorf("%s: %w", file.path, err)
		}
		found := mainTemplateProblems(file.name, document)
		if err = report(output, file.name, found); err != nil {
			return err
		}
		problems = append(problems, found...)
	}
	for _, file := range stageTemplates() {
		document, err := yamldoc.Load(filepath.Join(root, file.path), yamldoc.Options{})
		if err != nil {
			return fmt.Errorf("%s: %w", file.path, err)
		}
		var found []string
		if !document.Has("stages") && !document.Has("parameters") {
			found = append(found, file.name+": Missing both 'stages' and 'parameters' keys")
		}
		if err = report(output, file.name, found); err != nil {
			return err
		}
		problems = append(problems, found...)
	}
	return conclude(output, "\nErrors found:", problems)
}

func mainTemplateProblems(name string, document *yamldoc.Node) []string {
	var problems []string
	if !document.Has("stages") {
		problems = append(problems, name+": Missing 'stages' key")
	}
	if !document.Has("parameters") {
		problems = append(problems, name+": Missing 'parameters' key (expected for main templates)")
	}
	for index, stage := range document.Get("stages").Items() {
		if stage.Has("template") && !strings.HasSuffix(stage.Get("template").Text(), ".yaml") {
			problems = append(problems, fmt.Sprintf("%s: Stage %d template doesn't end with .yaml", name, index+1))
		}
	}
	return problems
}

// report prints the line of a template with no problem.
func report(output io.Writer, name string, problems []string) error {
	if len(problems) > 0 {
		return nil
	}
	return writeLines(output, "  ✓ "+name)
}

// conclude lists the problems under their heading and fails when there are any.
func conclude(output io.Writer, heading string, problems []string) error {
	if len(problems) == 0 {
		return nil
	}
	if err := writeLines(output, heading); err != nil {
		return err
	}
	for _, problem := range problems {
		if err := writeLines(output, "  ✗ "+problem); err != nil {
			return err
		}
	}
	return errFailed
}

// checkParameters holds every main template to defining each parameter it
// references; a parameter defined and never used is a warning only.
func checkParameters(root string, output io.Writer) error {
	var problems, warnings []string
	for _, file := range mainTemplates() {
		undefined, unused, err := templateGaps(root, file)
		if err != nil {
			return err
		}
		for _, name := range undefined {
			problems = append(problems, fmt.Sprintf("%s: Parameter '%s' referenced but not defined", file.name, name))
		}
		for _, name := range unused {
			warnings = append(warnings, fmt.Sprintf("%s: Parameter '%s' defined but not used", file.name, name))
		}
		if len(undefined) == 0 && len(unused) == 0 {
			if err = writeLines(output, "  ✓ "+file.name); err != nil {
				return err
			}
		}
	}
	if len(warnings) > 0 {
		lines := []string{"\nWarnings:"}
		for _, warning := range warnings {
			lines = append(lines, "  ⚠ "+warning)
		}
		if err := writeLines(output, lines...); err != nil {
			return err
		}
	}
	return conclude(output, "\nErrors:", problems)
}

// templateGaps reads one main template and returns its parameterGaps.
func templateGaps(root string, file template) ([]string, []string, error) {
	content, err := os.ReadFile(filepath.Join(root, file.path))
	if err != nil {
		return nil, nil, err
	}
	document, err := yamldoc.Parse(content, yamldoc.Options{})
	if err != nil {
		return nil, nil, fmt.Errorf("%s: %w", file.path, err)
	}
	undefined, unused, err := parameterGaps(string(content), document)
	if err != nil {
		return nil, nil, fmt.Errorf("%s: %w", file.path, err)
	}
	return undefined, unused, nil
}

// parameterGaps are the parameters a template references without defining,
// and those it defines without referencing, each sorted.
func parameterGaps(content string, document *yamldoc.Node) ([]string, []string, error) {
	if !document.Has("parameters") {
		return nil, nil, nil
	}
	referenced := map[string]bool{}
	for _, match := range parameterReference.FindAllStringSubmatch(content, -1) {
		referenced[match[1]] = true
	}
	defined := map[string]bool{}
	for index, parameter := range document.Get("parameters").Items() {
		if !parameter.Has("name") {
			return nil, nil, fmt.Errorf("parameter %d has no name", index+1)
		}
		defined[parameter.Get("name").Str()] = true
	}
	return difference(referenced, defined), difference(defined, referenced), nil
}

func difference(from, without map[string]bool) []string {
	var left []string
	for name := range from {
		if !without[name] {
			left = append(left, name)
		}
	}
	sort.Strings(left)
	return left
}

// checkSAM holds a SAM template to parsing, CloudFormation's intrinsic tags
// (`!Sub`, `!GetAtt`) accepted, and to the keys every SAM template carries.
func checkSAM(path string) error {
	document, err := yamldoc.Load(path, yamldoc.Options{ApplicationTags: true})
	if err != nil {
		return errFailed
	}
	for _, key := range []string{"AWSTemplateFormatVersion", "Transform", "Resources"} {
		if !document.Has(key) {
			return errFailed
		}
	}
	return nil
}

// checkYAML holds a file to parsing as YAML.
func checkYAML(path string) error {
	if _, err := yamldoc.Load(path, yamldoc.Options{}); err != nil {
		return errFailed
	}
	return nil
}

// checkJSON holds a file to being one JSON document in UTF-8.
func checkJSON(path string) error {
	content, err := os.ReadFile(
		path,
	) //nolint:gosec // G703: the file to check is the one the suite names; reading it is the point
	if err != nil || !utf8.Valid(content) || !json.Valid(content) {
		return errFailed
	}
	return nil
}
