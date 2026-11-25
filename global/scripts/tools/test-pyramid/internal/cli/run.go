// Package cli is the test-pyramid check's command line. It resolves what a pipeline gives it --
// the target branch, the suites to judge, the report directory -- wires the git repositories to
// the command, and turns the command's outcome into the job's log, reports and exit status.
//
// Usage: test-pyramid [target-branch]
//
// The target branch defaults to the pull request's (Azure DevOps, GitHub Actions and GitLab CI each
// name it), then to the default branch of `origin`, then to `main`. The environment:
//
//	TEST_PYRAMID_LANGUAGE  the suites to judge, space-separated; `languages` in .test-pyramid wins
//	TEST_PYRAMID_TARGET    the target branch, when no argument names it
//	TEST_PYRAMID_BASE      a commit to compare with instead of the merge base
//	TEST_PYRAMID_BLOCKING  `true` makes a worsened pyramid fail whatever .test-pyramid says; only
//	                       the target branch's .test-pyramid can make the check advisory again
//	REPORT_PATH            where the reports go (build/reports/test-pyramid)
//
// Exit status: 0 when the pull request keeps the pyramid, or worsens it under an advisory policy;
// 1 when it worsens it under a blocking one; 2 when the check could not run.
package cli

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	"github.com/rios0rios0/pipelines/global/scripts/tools/test-pyramid/internal/domain/commands"
	"github.com/rios0rios0/pipelines/global/scripts/tools/test-pyramid/internal/domain/entities"
	"github.com/rios0rios0/pipelines/global/scripts/tools/test-pyramid/internal/infrastructure/reports"
	"github.com/rios0rios0/pipelines/global/scripts/tools/test-pyramid/internal/infrastructure/repositories"
)

const (
	exitKept     = 0
	exitWorsened = 1
	exitSetup    = 2

	defaultReportPath = "build/reports/test-pyramid"
	defaultTarget     = "main"
)

// Run is the whole command: it reads `arguments` and `getenv`, writes to `stdout` and `stderr`,
// and returns the exit status.
func Run(arguments []string, getenv func(string) string, stdout, stderr io.Writer) int {
	setup := func(err error) int {
		_, _ = fmt.Fprintf(stderr, "test-pyramid: %s\n", neutralize(err.Error()))
		return exitSetup
	}
	argument, err := targetArgument(arguments)
	if err != nil {
		return setup(err)
	}
	forceBlocking, err := blockingOverride(getenv("TEST_PYRAMID_BLOCKING"))
	if err != nil {
		return setup(err)
	}
	directory, err := os.Getwd()
	if err != nil {
		return setup(err)
	}
	root, err := repositories.FindRepositoryRoot(directory)
	if err != nil {
		return setup(err)
	}
	revisions, err := repositories.NewGitRevisionsRepository(root)
	if err != nil {
		return setup(err)
	}
	trees, err := repositories.NewGitTreesRepository(root)
	if err != nil {
		return setup(err)
	}
	request := entities.Request{
		Target:        resolveTarget(argument, getenv, revisions.FindDefaultBranch),
		Base:          getenv("TEST_PYRAMID_BASE"),
		Languages:     strings.Fields(getenv("TEST_PYRAMID_LANGUAGE")),
		ForceBlocking: forceBlocking,
	}
	publisher := publisher{
		directory: reportDirectory(root, getenv("REPORT_PATH")),
		platform:  reports.DetectPlatform(getenv),
		stdout:    stdout,
		stderr:    stderr,
	}
	status := exitSetup
	commands.NewJudgeTestPyramidCommand(revisions, trees, entities.Profiles()).Execute(request,
		commands.JudgeTestPyramidCommandListeners{
			OnKept:     func(report entities.Report) { status = publisher.publish(report) },
			OnWorsened: func(report entities.Report) { status = publisher.publish(report) },
			OnError:    func(judgeErr error) { status = setup(judgeErr) },
		})
	return status
}

// targetArgument is the target branch the command line names, "" when it names none.
func targetArgument(arguments []string) (string, error) {
	switch {
	case len(arguments) == 0:
		return "", nil
	case len(arguments) > 1 || strings.HasPrefix(arguments[0], "-"):
		return "", fmt.Errorf("usage: test-pyramid [target-branch], not %q", strings.Join(arguments, " "))
	default:
		return arguments[0], nil
	}
}

// blockingOverride is whether TEST_PYRAMID_BLOCKING insists on blocking. A value other than `true`,
// `false` or nothing is refused rather than read as advisory.
func blockingOverride(value string) (bool, error) {
	switch value {
	case "", "false":
		return false, nil
	case "true":
		return true, nil
	default:
		return false, fmt.Errorf("TEST_PYRAMID_BLOCKING must be 'true' or 'false', not %q", value)
	}
}

// resolveTarget is the target branch: the argument, TEST_PYRAMID_TARGET, the pull request's as the
// platform names it, the default branch of `origin`, or `main`. Azure DevOps names the full ref
// (`refs/heads/main`) of an Azure Repos pull request and the bare branch of a GitHub one; GitHub
// Actions and GitLab CI name the branch.
func resolveTarget(argument string, getenv func(string) string, defaultBranch func() string) string {
	target := argument
	for _, name := range []string{
		"TEST_PYRAMID_TARGET", "SYSTEM_PULLREQUEST_TARGETBRANCH", "GITHUB_BASE_REF", "CI_MERGE_REQUEST_TARGET_BRANCH_NAME",
	} {
		if target != "" {
			break
		}
		target = getenv(name)
	}
	if target == "" {
		target = defaultBranch()
	}
	target = strings.TrimPrefix(target, "refs/heads/")
	if target == "" {
		return defaultTarget
	}
	return target
}

// reportDirectory is REPORT_PATH, relative to the repository's root, or the default.
func reportDirectory(root, path string) string {
	if path == "" {
		path = defaultReportPath
	}
	if filepath.IsAbs(path) {
		return path
	}
	return filepath.Join(root, path)
}

// publisher turns a judgement into the job's output: the reports, the log, the summary, the
// annotation and the exit status.
type publisher struct {
	directory string
	platform  reports.Platform
	stdout    io.Writer
	stderr    io.Writer
}

func (p publisher) publish(report entities.Report) int {
	summary, err := reports.Write(report, p.directory)
	if err != nil {
		_, _ = fmt.Fprintf(p.stderr, "test-pyramid: cannot write the reports: %s\n", err)
		return exitSetup
	}
	_, _ = io.WriteString(p.stdout, reports.Text(report))
	if err = p.platform.PublishSummary(p.stdout, summary); err != nil {
		_, _ = fmt.Fprintf(p.stderr, "test-pyramid: WARNING: cannot publish the job summary: %s\n", err)
	}
	worsened := strings.Join(report.Worsened(), ", ")
	if worsened == "" {
		_, _ = io.WriteString(p.stdout, "\ntest-pyramid: this pull request keeps the test pyramid\n")
		return exitKept
	}
	if report.Blocking {
		p.platform.Annotate(
			p.stdout,
			"error",
			"This pull request worsens the test pyramid of: "+worsened+". See the job summary.",
		)
		_, _ = io.WriteString(p.stdout, "\n"+strings.Join([]string{
			"============================================================",
			"  ERROR: this pull request worsens the test pyramid.",
			"",
			"  Each WORSENED line above names what grew. Cover the",
			"  behaviour with tests further down the pyramid -- unit",
			"  tests first -- or move a test into the tier of what it",
			"  exercises. The per-file decisions are in the report:",
			"  " + p.directory,
			"============================================================",
		}, "\n")+"\n")
		return exitWorsened
	}
	p.platform.Annotate(p.stdout, "warning", "This pull request worsens the test pyramid of: "+worsened+
		". Advisory: 'blocking true' in the target branch's .test-pyramid makes it fail.")
	_, _ = fmt.Fprintf(p.stdout, "\ntest-pyramid: WARNING: this pull request worsens the test pyramid of: %s. "+
		"The check is advisory here, so the job passes; 'blocking true' in the target branch's .test-pyramid "+
		"makes it fail.\n", worsened)
	return exitKept
}

// neutralize keeps an error message, which may quote a pull request's own `.test-pyramid`, from
// being read by the platform as a command: GitHub Actions' `::` at the start of a line, Azure
// DevOps' `##vso[` and `##[` anywhere in one.
func neutralize(message string) string {
	lines := strings.Split(message, "\n")
	for index, line := range lines {
		line = strings.NewReplacer("##vso[", "##vso?", "##[", "##?").Replace(line)
		if strings.HasPrefix(strings.TrimLeft(line, " \t"), "::") {
			line = "?" + line
		}
		lines[index] = line
	}
	return strings.Join(lines, "\n")
}
