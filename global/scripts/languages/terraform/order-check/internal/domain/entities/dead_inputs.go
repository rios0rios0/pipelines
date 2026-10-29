package entities

import (
	"regexp"
	"strings"

	"github.com/rios0rios0/pipelines/global/scripts/languages/terraform/internal/text"
)

// sourcePath is the quoted value of a `source = "..."`.
var sourcePath = regexp.MustCompile(`source` + text.Space + `*=` + text.Space + `*"([^"]*)"`)

// LiteralStackPath is the literal `stacks/<path>` tail of the first `source`
// naming one, slashes trimmed; false when no source names `stacks/`, or when
// the stack part is interpolated -- the dynamic `stacks/${basename(...)}`
// form, whose directory is only known when Terragrunt parses it. The
// `${get_path_to_repo_root()}` prefix every source carries does not count.
func LiteralStackPath(source string) (string, bool) {
	const stacks = "stacks/"
	for _, match := range sourcePath.FindAllStringSubmatch(source, -1) {
		index := strings.Index(match[1], stacks)
		if index < 0 {
			continue
		}
		tail := match[1][index+len(stacks):]
		if strings.Contains(tail, "${") {
			return "", false
		}
		return strings.Trim(tail, "/"), true
	}
	return "", false
}

// DeclaredVariables are the names every source declares as a column-0
// `variable` block -- every `.tf` of a stack, not only `variables.tf`, since
// Terraform reads a declaration from any file.
func DeclaredVariables(sources []string) (map[string]bool, error) {
	names := map[string]bool{}
	for _, source := range sources {
		blocks, err := TopLevelBlocks(source, "variable")
		if err != nil {
			return nil, err
		}
		for _, block := range blocks {
			names[block.Name] = true
		}
	}
	return names, nil
}

// DeadInputs is rule F: the keys of a terragrunt file's `inputs = {}` no
// `variable` of its stack declares. Terraform silently ignores a `TF_VAR_`
// for a variable it does not declare, so such an input is passed and never
// read. Only top-level keys count -- a nested map key rides inside its
// entry's value. Reported, never removed: deleting content would break the
// only-permute guarantee of `--fix`, and the stack is resolved heuristically,
// so a wrong resolution must at worst produce a report to read.
func DeadInputs(source, path, stack string, declared map[string]bool) ([]Finding, error) {
	body, found, err := InputsBody(source)
	if err != nil || !found {
		return nil, err
	}
	entries, _ := SplitEntries(body)
	var dead []string
	for _, entry := range entries {
		if !declared[entry.Key] {
			dead = append(dead, entry.Key)
		}
	}
	if len(dead) == 0 {
		return nil, nil
	}
	return []Finding{errorFinding("dead-inputs", path, "input(s) not declared as a variable in "+stack+
		" (dead code -- remove them, or declare the variable): "+strings.Join(dead, ", "))}, nil
}
