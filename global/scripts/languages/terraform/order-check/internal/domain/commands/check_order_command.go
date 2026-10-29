// Package commands holds what the ordering checker does to a repository.
package commands

import (
	"strings"

	"github.com/rios0rios0/pipelines/global/scripts/languages/terraform/internal/paths"
	"github.com/rios0rios0/pipelines/global/scripts/languages/terraform/order-check/internal/domain/entities"
	"github.com/rios0rios0/pipelines/global/scripts/languages/terraform/order-check/internal/domain/repositories"
)

// declarations is a stack's declared variables, or a container -- a
// directory like `stacks/01_shared` with no `.tf` of its own, whose inputs
// belong to its sub-stacks and are left unchecked.
type declarations struct {
	names     map[string]bool
	container bool
}

// CheckOrderCommand checks, and with `fix` rewrites, a repository against
// the file-ordering standard.
type CheckOrderCommand struct {
	workspace repositories.WorkspaceRepository
	config    entities.Config
	declared  map[string]declarations
	fix       bool
}

// NewCheckOrderCommand wires the command to a repository and its config.
func NewCheckOrderCommand(workspace repositories.WorkspaceRepository, config entities.Config) *CheckOrderCommand {
	return &CheckOrderCommand{workspace: workspace, config: config}
}

// Execute runs every rule over the repository and returns the files that
// broke one or were rewritten, in the order they were checked: `root.hcl`
// files (rules A, B and F), each stack's `variables.tf` and `outputs.tf`
// (C and E), every `providers.tf` (D), then leaf `terragrunt.hcl` (F).
// Reading or parsing a file that cannot be read stops the run; files
// rewritten before that stay rewritten.
func (c *CheckOrderCommand) Execute(fix bool) ([]entities.FileResult, error) {
	c.fix, c.declared = fix, map[string]declarations{}
	inputsByStack := map[string]map[string]entities.Number{}
	var results []entities.FileResult
	for _, path := range c.workspace.Named(c.environments(), "root.hcl") {
		result, stack, inputs, skipped, err := c.checkRootHcl(path)
		if err != nil {
			return nil, err
		}
		if skipped {
			continue
		}
		if stack != "" {
			inputsByStack[stack] = inputs
		}
		results = append(results, result)
	}
	stackResults, err := c.checkStacks(inputsByStack)
	if err != nil {
		return nil, err
	}
	results = append(results, stackResults...)
	for _, step := range []func() ([]entities.FileResult, error){c.checkProviders, c.checkTerragrunt} {
		found, stepErr := step()
		if stepErr != nil {
			return nil, stepErr
		}
		results = append(results, found...)
	}
	var reported []entities.FileResult
	for _, result := range results {
		if len(result.Findings) > 0 || result.Fixed {
			reported = append(reported, result)
		}
	}
	return reported, nil
}

// environments is where `root.hcl` and `terragrunt.hcl` are looked for:
// `environments/` when the repository has one, the whole repository otherwise.
func (c *CheckOrderCommand) environments() string {
	directory := paths.Join(c.workspace.Root(), "environments")
	if c.workspace.IsDir(directory) {
		return directory
	}
	return c.workspace.Root()
}

// relative is a path as findings name it: relative to the repository.
func (c *CheckOrderCommand) relative(path string) string {
	if relative, ok := paths.RelativeTo(path, c.workspace.Root()); ok {
		return relative
	}
	return path
}

// ignored asks the config whether a path is ignored, by its relative name.
func (c *CheckOrderCommand) ignored(path string) (bool, error) {
	return c.config.IsIgnored(c.relative(path))
}

// apply writes a rewritten file when the run fixes and the rule changed it.
func (c *CheckOrderCommand) apply(path, rewritten string, changed bool, result *entities.FileResult) error {
	if !c.fix || !changed {
		return nil
	}
	if err := c.workspace.Write(path, rewritten); err != nil {
		return err
	}
	result.Fixed = true
	return nil
}

// checkRootHcl is rules A and B for one `root.hcl`, and rule F for its own
// inputs; it also yields the stack the file feeds and which dependency feeds
// each input, for rule C.
func (c *CheckOrderCommand) checkRootHcl(
	path string,
) (entities.FileResult, string, map[string]entities.Number, bool, error) {
	if skip, err := c.ignored(path); skip || err != nil {
		return entities.FileResult{}, "", nil, skip, err
	}
	source, err := c.workspace.Read(path)
	if err != nil {
		return entities.FileResult{}, "", nil, false, err
	}
	root, err := entities.ParseRootHcl(source)
	if err != nil {
		return entities.FileResult{}, "", nil, false, err
	}
	result := entities.FileResult{Path: c.relative(path)}
	findings, rewritten, changed, err := entities.CheckRootHcl(root, source, result.Path, c.fix)
	if err == nil {
		result.Findings = findings
		err = c.apply(path, rewritten, changed, &result)
	}
	if err != nil {
		return entities.FileResult{}, "", nil, false, err
	}
	dead, err := c.deadInputs(path)
	result.Findings = append(result.Findings, dead...)
	return result, root.Stack, root.Inputs, false, err
}

// checkStacks is rules C and E for every stack: discovered directly, so a
// stack that is new, unreferenced, or wired through a `source` the pattern
// misses is still checked. The dependency-number rule only applies once a
// `root.hcl` mapping was found for the stack; the marker and outputs rules
// apply to every stack.
func (c *CheckOrderCommand) checkStacks(
	inputsByStack map[string]map[string]entities.Number,
) ([]entities.FileResult, error) {
	var results []entities.FileResult
	for _, stack := range c.workspace.Directories(paths.Join(c.workspace.Root(), "stacks")) {
		inputs := inputsByStack[paths.Base(stack)]
		variables, outputs := paths.Join(stack, "variables.tf"), paths.Join(stack, "outputs.tf")
		checks := []struct {
			path  string
			check func(source, relative string) ([]entities.Finding, string, bool, error)
		}{
			{variables, func(source, relative string) ([]entities.Finding, string, bool, error) {
				return entities.CheckVariables(source, relative, inputs, c.fix)
			}},
			{outputs, func(source, relative string) ([]entities.Finding, string, bool, error) {
				return entities.CheckOutputs(source, relative, func() (map[string]int, error) {
					return c.mainPositions(stack)
				}, c.fix)
			}},
		}
		for _, file := range checks {
			result, checked, err := c.checkFile(file.path, file.check)
			if err != nil {
				return nil, err
			}
			if checked {
				results = append(results, result)
			}
		}
	}
	return results, nil
}

// checkFile runs one rule over a file that exists and is not ignored.
func (c *CheckOrderCommand) checkFile(
	path string, check func(source, relative string) ([]entities.Finding, string, bool, error),
) (entities.FileResult, bool, error) {
	if !c.workspace.IsFile(path) {
		return entities.FileResult{}, false, nil
	}
	if skip, err := c.ignored(path); skip || err != nil {
		return entities.FileResult{}, false, err
	}
	source, err := c.workspace.Read(path)
	if err != nil {
		return entities.FileResult{}, false, err
	}
	result := entities.FileResult{Path: c.relative(path)}
	findings, rewritten, changed, err := check(source, result.Path)
	if err == nil {
		result.Findings = findings
		err = c.apply(path, rewritten, changed, &result)
	}
	return result, err == nil, err
}

// checkProviders is rule D for every `providers.tf`: stacks, modules and a
// single-module repository alike.
func (c *CheckOrderCommand) checkProviders() ([]entities.FileResult, error) {
	var results []entities.FileResult
	for _, path := range c.workspace.Named(c.workspace.Root(), "providers.tf") {
		if skip, err := c.ignored(path); skip || err != nil {
			if err != nil {
				return nil, err
			}
			continue
		}
		source, err := c.workspace.Read(path)
		if err != nil {
			return nil, err
		}
		result := entities.FileResult{Path: c.relative(path)}
		findings, rewritten, changed, err := entities.CheckProviders(source, result.Path, c.config.Weights, c.fix)
		if err == nil {
			result.Findings = findings
			err = c.apply(path, rewritten, changed, &result)
		}
		if err != nil {
			return nil, err
		}
		results = append(results, result)
	}
	return results, nil
}

// checkTerragrunt is rule F for every leaf `terragrunt.hcl`: the per-instance
// overrides a root's inputs do not cover.
func (c *CheckOrderCommand) checkTerragrunt() ([]entities.FileResult, error) {
	var results []entities.FileResult
	for _, path := range c.workspace.Named(c.environments(), "terragrunt.hcl") {
		if skip, err := c.ignored(path); skip || err != nil {
			if err != nil {
				return nil, err
			}
			continue
		}
		findings, err := c.deadInputs(path)
		if err != nil {
			return nil, err
		}
		if len(findings) > 0 {
			results = append(results, entities.FileResult{Path: c.relative(path), Findings: findings})
		}
	}
	return results, nil
}

// deadInputs is rule F for one terragrunt file: nothing when its stack cannot
// be pinned down or is a container.
func (c *CheckOrderCommand) deadInputs(path string) ([]entities.Finding, error) {
	stack, found, err := c.resolveStack(path)
	if err != nil || !found {
		return nil, err
	}
	declared, known := c.declared[stack]
	if !known {
		if declared, err = c.collectDeclarations(stack); err != nil {
			return nil, err
		}
		c.declared[stack] = declared
	}
	if declared.container {
		return nil, nil
	}
	source, err := c.workspace.Read(path)
	if err != nil {
		return nil, err
	}
	return entities.DeadInputs(source, c.relative(path), c.relative(stack), declared.names)
}

// collectDeclarations reads every `.tf` of a stack for its declarations.
func (c *CheckOrderCommand) collectDeclarations(stack string) (declarations, error) {
	files := c.workspace.Matching(stack, "*.tf")
	if len(files) == 0 {
		return declarations{container: true}, nil
	}
	names := map[string]bool{}
	for _, file := range files {
		source, err := c.workspace.Read(file)
		if err != nil {
			return declarations{}, err
		}
		declared, err := entities.DeclaredVariables([]string{source})
		if err != nil {
			return declarations{}, err
		}
		for name := range declared {
			names[name] = true
		}
	}
	return declarations{names: names}, nil
}

// resolveStack is the `stacks/<...>` directory a terragrunt file feeds: the
// literal `stacks/<path>` of its own `source` -- or, for a leaf, of the
// `root.hcl` it includes -- when that directory exists; else the longest
// prefix of the file's directory below `environments/` that exists below
// `stacks/`, which covers dynamic sources and nested sub-stacks. False when
// neither yields a directory: an unrecognised layout is skipped, never
// misreported.
func (c *CheckOrderCommand) resolveStack(path string) (string, bool, error) {
	source, err := c.workspace.Read(path)
	if err != nil {
		return "", false, err
	}
	literal, found := entities.LiteralStackPath(source)
	if !found {
		if root, hasRoot := c.parentRootHcl(path); hasRoot {
			if source, err = c.workspace.Read(root); err != nil {
				return "", false, err
			}
			literal, found = entities.LiteralStackPath(source)
		}
	}
	stacks := paths.Join(c.workspace.Root(), "stacks")
	if found && literal != "" {
		if candidate := paths.Join(stacks, literal); c.workspace.IsDir(candidate) {
			return candidate, true, nil
		}
	}
	relative, ok := paths.RelativeTo(paths.Dir(path), paths.Join(c.workspace.Root(), "environments"))
	if !ok || relative == "." {
		return "", false, nil
	}
	parts := strings.Split(relative, "/")
	for count := len(parts); count > 0; count-- {
		if candidate := paths.Join(stacks, strings.Join(parts[:count], "/")); c.workspace.IsDir(candidate) {
			return candidate, true, nil
		}
	}
	return "", false, nil
}

// parentRootHcl is the nearest `root.hcl` above a file -- what Terragrunt's
// `find_in_parent_folders` finds -- not the file itself, not above the
// repository.
func (c *CheckOrderCommand) parentRootHcl(path string) (string, bool) {
	for directory := paths.Dir(path); ; directory = paths.Dir(directory) {
		if candidate := paths.Join(directory, "root.hcl"); c.workspace.IsFile(candidate) && candidate != path {
			return candidate, true
		}
		if directory == c.workspace.Root() || paths.Dir(directory) == directory {
			return "", false
		}
	}
}

// mainPositions reads a stack's `main*.tf` for rule E.
func (c *CheckOrderCommand) mainPositions(stack string) (map[string]int, error) {
	files := c.workspace.Matching(stack, "main*.tf")
	byName := map[string]string{}
	names := make([]string, 0, len(files))
	for _, file := range files {
		byName[paths.Base(file)] = file
		names = append(names, paths.Base(file))
	}
	entities.SortMains(names)
	sources := make([]string, 0, len(names))
	for _, name := range names {
		source, err := c.workspace.Read(byName[name])
		if err != nil {
			return nil, err
		}
		sources = append(sources, source)
	}
	return entities.MainPositions(sources), nil
}
