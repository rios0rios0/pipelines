// Package cli is the dependency-updates command line: it parses the arguments,
// wires the commands to the network or to an offline fixture, and turns their
// results into reports and an exit status.
//
// The command reports every pinned third-party dependency that
// has a newer release upstream, or a known vulnerability, and with `--apply`
// rewrites each one -- digests, vendored files and inline copies included --
// and writes the pull request that proposes it. `verify` proves a pull request
// that moves pins safe to merge; `guard` decides whether the update branch may
// be regenerated.
//
// Everything this repository executes is pinned: actions to a commit SHA,
// images to a digest, binaries to a version plus a committed SHA-256. That is
// what makes a pipeline reproducible, and it is also what makes it go stale
// silently -- a pin never tells you it is three CVEs behind. This is the half
// that tells a person when to decide, and refuses to propose anything known to
// be unsafe.
//
// Exit codes: 0 nothing needs a person; 1 something does (an update that
// cannot be applied safely, a pin nothing can check, a known vulnerability in
// a pin in use, a pull request that fails verification); 2 an upstream or the
// advisory database could not be consulted -- deliberately NOT reported as
// clean, because a rate-limited API must never look like a green light.
package cli

import (
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"time"

	"github.com/rios0rios0/pipelines/global/scripts/tools/dependency-updates/internal/domain/commands"
	"github.com/rios0rios0/pipelines/global/scripts/tools/dependency-updates/internal/domain/entities"
	"github.com/rios0rios0/pipelines/global/scripts/tools/dependency-updates/internal/infrastructure/reports"
	infrastructure "github.com/rios0rios0/pipelines/global/scripts/tools/dependency-updates/internal/infrastructure/repositories"
)

const (
	exitClean        = 0
	exitNeedsPerson  = 1
	exitLookupFailed = 2
	defaultJobs      = 8
	reportFileMode   = 0o600
	reportDirMode    = 0o750
)

var (
	repositoryPattern  = regexp.MustCompile(`^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$`)
	fingerprintPattern = regexp.MustCompile(`^[0-9a-f]{64}$`)
)

// errUsage is a command line that cannot be run; the message is already out.
var errUsage = errors.New("usage")

// Run is the whole command, run from the process's working directory,
// writing to `stdout` and `stderr`, returning the exit status.
func Run(arguments []string, stdout, stderr io.Writer) int {
	workdir, err := os.Getwd()
	if err != nil {
		_, _ = fmt.Fprintf(stderr, errorLine, err)
		return exitLookupFailed
	}
	return RunIn(workdir, arguments, stdout, stderr)
}

// RunIn is the whole command, with relative paths resolved against `workdir`
// and `--report` and `--fixture` confined to it.
func RunIn(workdir string, arguments []string, stdout, stderr io.Writer) int {
	if len(arguments) > 0 {
		switch arguments[0] {
		case "guard":
			return runGuard(workdir, arguments[1:], stdout, stderr)
		case "verify":
			return runVerify(workdir, arguments[1:], stdout, stderr)
		}
	}
	return runCheck(workdir, arguments, stdout, stderr)
}

// errorLine is how a failure is reported on the console.
const errorLine = "ERROR: %s\n"

type runOptions struct {
	repoDir      string
	report       string
	fixture      string
	now          time.Time
	cooldownDays int
	jobs         int
	timestamp    string
	changelog    string
	reportOnly   bool
	apply        bool
	verifyAssets bool
	scanImages   bool
	scanner      string
	installer    string
}

func commonFlags(set *flag.FlagSet, options *runOptions, now, cooldown *string) {
	set.StringVar(&options.repoDir, "repo-dir", ".", "repository root to scan")
	set.StringVar(
		&options.report,
		"report",
		envOr("REPORT_PATH", "build/reports"),
		"directory for the JSON and Markdown reports",
	)
	set.StringVar(
		&options.fixture,
		"fixture",
		os.Getenv("DEPENDENCY_UPDATES_FIXTURE"),
		"JSON of upstream answers; makes the run offline",
	)
	set.IntVar(&options.jobs, "jobs", defaultJobs, "parallel upstream lookups")
	set.StringVar(now, "now", "", "RFC 3339 time the cooldown and acceptances are judged at (default: now)")
	set.BoolVar(&options.scanImages, "scan-images", true,
		"scan a re-pinned container image against the one it replaces (exports from the registry; no Docker needed)")
	set.StringVar(&options.scanner, "osv-scanner", "osv-scanner", "the osv-scanner binary images are scanned with")
	set.StringVar(&options.installer, "osv-scanner-installer", "",
		"run once, before the first image is scanned, to install --osv-scanner (default: install nothing)")
	set.StringVar(cooldown, "cooldown-days", os.Getenv("DEPENDENCY_UPDATES_COOLDOWN_DAYS"),
		"minimum age, in days, of a release before it is proposed (default: the settings file, then 7)")
}

func finishOptions(options *runOptions, now, cooldown string, stderr io.Writer) error {
	options.now = time.Now().UTC()
	if now != "" {
		parsed, err := parseTime(now)
		if err != nil {
			_, _ = fmt.Fprintf(stderr, "ERROR: --now: %s\n", err)
			return errUsage
		}
		options.now = parsed
	}
	options.cooldownDays = -1
	if cooldown != "" {
		days, err := strconv.Atoi(cooldown)
		if err != nil || days < 0 {
			_, _ = fmt.Fprintf(stderr, "ERROR: --cooldown-days must be a whole number of days, got %q\n", cooldown)
			return errUsage
		}
		options.cooldownDays = days
	}
	return nil
}

func parseTime(value string) (time.Time, error) {
	for _, layout := range []string{time.RFC3339, "2006-01-02T15:04:05", time.DateOnly} {
		if parsed, err := time.Parse(layout, value); err == nil {
			return parsed.UTC(), nil
		}
	}
	return time.Time{}, fmt.Errorf("%q is not an RFC 3339 time", value)
}

func envOr(name, fallback string) string {
	if value := os.Getenv(name); value != "" {
		return value
	}
	return fallback
}

func parseCheckFlags(arguments []string, stderr io.Writer) (runOptions, error) {
	var (
		options       runOptions
		now, cooldown string
	)
	set := flag.NewFlagSet("dependency-updates", flag.ContinueOnError)
	set.SetOutput(stderr)
	commonFlags(set, &options, &now, &cooldown)
	set.BoolVar(&options.reportOnly, "report-only", false, "always exit 0; report without failing the build")
	set.BoolVar(
		&options.apply,
		"apply",
		false,
		"rewrite every proposed pin in --repo-dir and write the pull request into --report",
	)
	set.BoolVar(
		&options.verifyAssets,
		"verify-assets",
		false,
		"check every `# asset:` template against its committed digest (network)",
	)
	set.StringVar(
		&options.timestamp,
		"timestamp",
		"",
		"RFC 3339 time for the changelog entry --apply writes (default: HEAD's commit time)",
	)
	set.StringVar(
		&options.changelog,
		"changelog",
		"auto",
		"auto|none: whether --apply records the change in the changelog",
	)
	if err := set.Parse(arguments); err != nil {
		return options, errUsage
	}
	modes := 0
	for _, enabled := range []bool{options.reportOnly, options.apply, options.verifyAssets} {
		if enabled {
			modes++
		}
	}
	if modes > 1 {
		_, _ = fmt.Fprintln(stderr, "ERROR: --report-only, --apply and --verify-assets are mutually exclusive")
		return options, errUsage
	}
	if options.changelog != "auto" && options.changelog != "none" {
		_, _ = fmt.Fprintf(stderr, "ERROR: --changelog must be auto or none, got %q\n", options.changelog)
		return options, errUsage
	}
	return options, finishOptions(&options, now, cooldown, stderr)
}

// withinWorkdir resolves a command-line path and requires it to stay inside
// the working tree. Both paths it guards -- `--report` and `--fixture` -- are
// written to or read from, so "wherever you point me" is the wrong contract for
// a CI tool; a traversal (`--report ../../etc`) fails here rather than
// somewhere surprising. Resolved through symlinks first, so a symlink cannot be
// used to step outside after the check.
func withinWorkdir(workdir, raw, purpose string) (string, error) {
	base, resolved := realPath(workdir), realPath(absolute(workdir, raw))
	if resolved != base && !isWithin(base, resolved) {
		return "", fmt.Errorf(
			"refusing to use '%s' for %s: it resolves outside the working directory '%s'",
			raw,
			purpose,
			base,
		)
	}
	return resolved, nil
}

// absolute is `path` resolved against `workdir` when it is relative.
func absolute(workdir, path string) string {
	if filepath.IsAbs(path) {
		return filepath.Clean(path)
	}
	return filepath.Join(workdir, path)
}

// realPath resolves every symlink of the part of an absolute `path` that
// exists, and keeps the rest as written -- what Python's os.path.realpath does.
func realPath(path string) string {
	existing, rest := filepath.Clean(path), ""
	for {
		if resolved, resolveErr := filepath.EvalSymlinks(existing); resolveErr == nil {
			return filepath.Join(resolved, rest)
		}
		parent := filepath.Dir(existing)
		if parent == existing {
			return filepath.Clean(path)
		}
		rest = filepath.Join(filepath.Base(existing), rest)
		existing = parent
	}
}

func isWithin(base, path string) bool {
	relative, err := filepath.Rel(base, path)
	return err == nil && relative != ".." && !filepath.IsAbs(relative) &&
		(len(relative) < 3 || relative[:3] != ".."+string(filepath.Separator))
}

// reportFile joins a report file name onto the report directory, refusing to
// escape it. The directory is the caller's choice and may legitimately be
// absolute; what is confined is the part this command constructs.
func reportFile(directory, name string) (string, error) {
	resolved := realPath(filepath.Join(directory, name))
	if filepath.Dir(resolved) != realPath(directory) {
		return "", fmt.Errorf("refusing to write '%s' outside the report directory '%s'", name, directory)
	}
	return resolved, nil
}

// loadFixture is the fixture `raw` names, or none for a live run; false when it
// cannot be loaded, the reason already reported.
func loadFixture(workdir, raw string, stderr io.Writer) (infrastructure.Fixture, bool) {
	if raw == "" {
		return nil, true
	}
	fixture, err := readFixture(workdir, raw)
	if err != nil {
		_, _ = fmt.Fprintln(stderr, err)
		return nil, false
	}
	return fixture, true
}

// readFixture loads an offline fixture, refusing anything that is not a readable
// file inside the working directory.
func readFixture(workdir, raw string) (infrastructure.Fixture, error) {
	path, err := withinWorkdir(workdir, raw, "the offline fixture")
	if err != nil {
		return nil, err
	}
	info, err := os.Stat(path) //nolint:gosec // G703: confined to the working directory by withinWorkdir above
	if err != nil || !info.Mode().IsRegular() {
		return nil, fmt.Errorf("fixture file not found: %s", raw)
	}
	content, err := os.ReadFile(path) //nolint:gosec // G304: the path was confined to the working directory above
	if err != nil {
		return nil, err
	}
	return infrastructure.ParseFixture(content)
}

func runCheck(workdir string, arguments []string, stdout, stderr io.Writer) int {
	options, err := parseCheckFlags(arguments, stderr)
	if err != nil {
		return exitLookupFailed
	}
	fixture, loaded := loadFixture(workdir, options.fixture, stderr)
	if !loaded {
		return exitNeedsPerson
	}
	wiring, err := newContainer(absolute(workdir, options.repoDir), fixture, options, stderr)
	if err != nil {
		_, _ = fmt.Fprintf(stderr, errorLine, err)
		return exitLookupFailed
	}
	defer wiring.close()
	console := reports.NewConsole(stdout, stderr)
	if options.verifyAssets {
		return verifyAssets(wiring, console)
	}
	// Resolved against the WORKING DIRECTORY, not `--repo-dir`: the directory
	// being scanned is a separate question from where the report belongs, and
	// resolving it against the scan root wrote reports into the inspected
	// repository whenever the two differed. Checked before anything is looked
	// up or rewritten, so a bad path fails without having touched anything.
	reportDir, err := withinWorkdir(workdir, options.report, "the report directory")
	if err != nil {
		_, _ = fmt.Fprintln(stderr, err)
		return exitNeedsPerson
	}
	return check(wiring, options, reportDir, fixture != nil, console)
}

func verifyAssets(wiring *container, console *reports.Console) int {
	checks := wiring.verifyAssetsCommand().Execute(entities.ParseManifest(wiring.workspace.Text(entities.ManifestPath)))
	console.AssetChecks(checks)
	worst := exitClean
	for _, check := range checks {
		switch check.Status {
		case commands.AssetError:
			return exitLookupFailed
		case commands.AssetMissing, commands.AssetMismatch:
			worst = exitNeedsPerson
		}
	}
	return worst
}

func check(wiring *container, options runOptions, reportDir string, offline bool, console *reports.Console) int {
	command := wiring.checkCommand()
	result := command.Discover()
	if len(result.Tasks) == 0 {
		console.Errorf("ERROR: no pinned dependencies discovered -- is --repo-dir correct?\n")
		return exitLookupFailed
	}
	source := "live upstreams"
	if offline {
		source = "offline fixture"
	}
	console.Printf("Checking %d pinned dependencies (%s)...\n", len(result.Tasks), source)
	result = command.Execute(result)
	console.Findings(result)

	var (
		apply       *commands.ApplyResult
		pullRequest *reports.PullRequestRecord
	)
	if options.apply {
		applied := wiring.applyCommand().Execute(result)
		apply = &applied
		console.Applied(applied)
	} else {
		console.Refused(result.Refused())
	}
	console.Errors(result)
	if err := os.MkdirAll(reportDir, reportDirMode); err != nil {
		console.Errorf(errorLine, err)
		return exitLookupFailed
	}
	if apply != nil {
		record, err := writePullRequest(wiring, options, result, *apply, reportDir, console)
		if err != nil {
			console.Errorf(errorLine, err)
			return exitLookupFailed
		}
		pullRequest = record
	}
	if err := writeReports(result, apply, pullRequest, reportDir); err != nil {
		console.Errorf(errorLine, err)
		return exitLookupFailed
	}
	console.Printf("\nReports written to %s\n", reportDir)
	return checkStatus(result, apply, options, console)
}

func writeReports(
	result commands.CheckResult,
	apply *commands.ApplyResult,
	pullRequest *reports.PullRequestRecord,
	reportDir string,
) error {
	payload, err := reports.JSON(result, pullRequest)
	if err != nil {
		return err
	}
	files := map[string]string{
		"dependency-updates.json": string(payload) + "\n",
		"dependency-updates.md":   reports.Summary(result, apply),
	}
	return writeFiles(reportDir, files)
}

func writeFiles(reportDir string, files map[string]string) error {
	for name, content := range files {
		path, err := reportFile(reportDir, name)
		if err != nil {
			return err
		}
		if writeErr := os.WriteFile(path, []byte(content), reportFileMode); writeErr != nil {
			return writeErr
		}
	}
	return nil
}

// writePullRequest writes the updates into the repository, records them in its
// changelog, and writes the pull request's title, body, commit message and
// fingerprint into the report directory. It never commits: the workflow opens
// the pull request, and `make apply-dependency-updates` leaves the change for
// `git diff`.
func writePullRequest(
	wiring *container, options runOptions, result commands.CheckResult, apply commands.ApplyResult,
	reportDir string, console *reports.Console,
) (*reports.PullRequestRecord, error) {
	fingerprint := entities.Fingerprint(apply.Applied, apply.Fixes)
	changelog := ""
	if len(wiring.workspace.Changed()) > 0 && options.changelog == "auto" {
		explicit := time.Time{}
		if options.timestamp != "" {
			parsed, err := parseTime(options.timestamp)
			if err != nil {
				return nil, fmt.Errorf("--timestamp: %w", err)
			}
			explicit = parsed
		}
		changelog = wiring.changelogCommand().
			Execute(reports.ChangelogEntries(apply.Applied, apply.Fixes), fingerprint, explicit)
	}
	written, err := wiring.workspace.Write()
	if err != nil {
		return nil, err
	}
	title := reports.Title(apply.Applied, apply.Fixes)
	files := map[string]string{
		"pull-request-title.txt": title + "\n",
		"pull-request.md": reports.PullRequestBody(reports.PullRequestInput{
			Check: result, Apply: apply, Fingerprint: fingerprint, Changelog: changelog,
		}),
		"commit-message.txt": reports.CommitMessage(apply.Applied, apply.Fixes, fingerprint),
		"fingerprint.txt":    fingerprint + "\n",
	}
	if err = writeFiles(reportDir, files); err != nil {
		return nil, err
	}
	console.Printf("\n%s rewritten in %s.\n", reports.Plural(len(written), "file"), wiring.workspace.Root())
	return reports.NewPullRequestRecord(apply, title, fingerprint, changelog, written), nil
}

func checkStatus(
	result commands.CheckResult,
	apply *commands.ApplyResult,
	options runOptions,
	console *reports.Console,
) int {
	if options.reportOnly {
		return exitClean
	}
	// A lookup that could not be completed fails the run. Reporting it as "up
	// to date" would turn a rate-limited API into a green light that checked
	// nothing, which is worse than not running this at all.
	if failed := len(result.Failed()); failed > 0 || result.AdvisoryError != "" {
		if result.AdvisoryError != "" {
			failed++
		}
		console.Errorf("\n%d upstream lookup(s) failed; refusing to report a clean result.\n", failed)
		return exitLookupFailed
	}
	vulnerable := len(result.Vulnerable())
	if apply != nil {
		return applyStatus(*apply, result, vulnerable, console)
	}
	proposals, refused := len(result.Proposals()), len(result.Refused())
	if proposals > 0 || refused > 0 || len(result.Drift) > 0 || len(result.Untracked) > 0 || vulnerable > 0 {
		console.Printf("\n%d update(s), %d refused, %d drifted copy/copies, %d untracked pin(s), "+
			"%d known-vulnerable pin(s).\n", proposals, refused, len(result.Drift), len(result.Untracked), vulnerable)
		return exitNeedsPerson
	}
	console.Printf("\nEvery pinned dependency is current.\n")
	return exitClean
}

// applyStatus: applied updates and realigned copies are the pull request's job
// now; what is left is what a pull request cannot carry -- and a known
// vulnerability in a pin in use, which keeps the job red until the pull
// request removing it is merged.
func applyStatus(
	apply commands.ApplyResult,
	result commands.CheckResult,
	vulnerable int,
	console *reports.Console,
) int {
	status := exitClean
	switch {
	case len(apply.Refused) > 0 || len(result.Untracked) > 0:
		console.Printf("\n%s could not be applied, %s untracked.\n", reports.Plural(len(apply.Refused), "update"),
			reports.Plural(len(result.Untracked), "pin"))
		status = exitNeedsPerson
	case len(apply.Applied)+len(apply.Fixes) > 0:
		console.Printf("\n%s applied.\n", reports.Plural(len(apply.Applied)+len(apply.Fixes), "change"))
	default:
		console.Printf("\nEvery pinned dependency is current.\n")
	}
	if vulnerable > 0 {
		verb := "have"
		if vulnerable == 1 {
			verb = "has"
		}
		console.Printf("%s on the scanned branch %s known vulnerabilities; the job stays red until they are gone.\n",
			reports.Plural(vulnerable, "pin"), verb)
		status = exitNeedsPerson
	}
	return status
}

func runGuard(workdir string, arguments []string, stdout, stderr io.Writer) int {
	set := flag.NewFlagSet("dependency-updates guard", flag.ContinueOnError)
	set.SetOutput(stderr)
	repository := set.String("repository", os.Getenv("GITHUB_REPOSITORY"), "owner/name")
	branch := set.String("branch", "", "the branch the pull request is opened from")
	base := set.String("base", "", "the branch the pull request targets")
	fingerprint := set.String("fingerprint", "", "the fingerprint --apply wrote")
	fixtureFlag := set.String(
		"fixture",
		os.Getenv("DEPENDENCY_UPDATES_FIXTURE"),
		"JSON of `GET <url>` answers; makes the run offline",
	)
	if err := set.Parse(arguments); err != nil {
		return exitLookupFailed
	}
	if *branch == "" || *base == "" {
		_, _ = fmt.Fprintln(stderr, "ERROR: --branch and --base are required")
		return exitLookupFailed
	}
	if !repositoryPattern.MatchString(*repository) {
		_, _ = fmt.Fprintf(stderr, "ERROR: --repository must be owner/name, got %q\n", *repository)
		return exitLookupFailed
	}
	if !fingerprintPattern.MatchString(*fingerprint) {
		_, _ = fmt.Fprintf(stderr, "ERROR: --fingerprint must be 64 hex characters, got %q\n", *fingerprint)
		return exitLookupFailed
	}
	fixture, loaded := loadFixture(workdir, *fixtureFlag, stderr)
	if !loaded {
		return exitLookupFailed
	}
	decision, err := guardCommand(fixture).Execute(*repository, *branch, *base, *fingerprint)
	if err != nil {
		_, _ = fmt.Fprintf(stderr, "ERROR: could not tell whether the pull request may be updated: %s\n", err)
		return exitLookupFailed
	}
	_, _ = fmt.Fprintf(stdout, "proceed=%t\nreason=%s\n", decision.Proceed, decision.Reason)
	return exitClean
}

func runVerify(workdir string, arguments []string, stdout, stderr io.Writer) int {
	var (
		options       runOptions
		now, cooldown string
		baseDir       string
	)
	set := flag.NewFlagSet("dependency-updates verify", flag.ContinueOnError)
	set.SetOutput(stderr)
	commonFlags(set, &options, &now, &cooldown)
	set.StringVar(&baseDir, "base-dir", "", "a checkout of the pull request's base")
	if err := set.Parse(arguments); err != nil || finishOptions(&options, now, cooldown, stderr) != nil {
		return exitLookupFailed
	}
	if baseDir == "" {
		_, _ = fmt.Fprintln(stderr, "ERROR: --base-dir is required")
		return exitLookupFailed
	}
	fixture, loaded := loadFixture(workdir, options.fixture, stderr)
	if !loaded {
		return exitLookupFailed
	}
	reportDir, err := withinWorkdir(workdir, options.report, "the report directory")
	if err != nil {
		_, _ = fmt.Fprintln(stderr, err)
		return exitLookupFailed
	}
	return verify(options, absolute(workdir, options.repoDir), absolute(workdir, baseDir), reportDir, fixture,
		reports.NewConsole(stdout, stderr))
}

func verify(
	options runOptions,
	headRoot, baseRoot, reportDir string,
	fixture infrastructure.Fixture,
	console *reports.Console,
) int {
	wiring, err := newContainer(headRoot, fixture, options, nil)
	if err != nil {
		console.Errorf(errorLine, err)
		return exitLookupFailed
	}
	defer wiring.close()
	base, err := infrastructure.NewFileWorkspaceRepository(baseRoot)
	if err != nil {
		console.Errorf("ERROR: --base-dir: %s\n", err)
		return exitLookupFailed
	}
	defer func() { _ = base.Close() }()
	result := wiring.verifyPullRequestCommand(base).Execute()
	console.Verification(result)
	if err = os.MkdirAll(reportDir, reportDirMode); err != nil {
		console.Errorf(errorLine, err)
		return exitLookupFailed
	}
	if err = writeFiles(reportDir, map[string]string{
		"verification.md": reports.Verification(result),
		// How many pins moved, or copies of one were left behind: what lets a
		// workflow stay silent on a pull request that touches none.
		"changes.txt": strconv.Itoa(len(result.Changes)+len(result.Drift)) + "\n",
	}); err != nil {
		console.Errorf(errorLine, err)
		return exitLookupFailed
	}
	console.Printf("\nReport written to %s\n", reportDir)
	return result.Exit()
}
