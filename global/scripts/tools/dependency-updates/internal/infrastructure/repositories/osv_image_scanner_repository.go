package repositories

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"time"

	"github.com/rios0rios0/pipelines/global/scripts/tools/dependency-updates/internal/domain/entities"
	"github.com/rios0rios0/pipelines/global/scripts/tools/dependency-updates/internal/domain/repositories"
)

const (
	// concurrentScans bounds how many images are downloaded and scanned at
	// once: each is up to hundreds of megabytes on the runner's disk.
	concurrentScans = 3
	scanTimeout     = 15 * time.Minute
	installTimeout  = 5 * time.Minute
	// OSV-Scanner's documented exit codes that are results, not failures.
	scannerFoundVulnerabilities = 1
	scannerFoundNoPackages      = 128
	stderrTail                  = 400
	scanFailed                  = "scanning %s: %s"
)

// OSVImageScannerRepository scans a container image with OSV-Scanner -- its OS
// packages (Debian, Ubuntu, Alpine...) and the artifacts it ships, such as Go
// binaries' embedded module lists -- against the same OSV.dev database the
// pins themselves are checked against. The image is exported from the registry
// by an ImageExporter, so no container daemon is needed.
//
// OSV-Scanner leaves out what the distribution itself triages as unimportant,
// which is what keeps a same-tag rebuild's comparison about real issues.
type OSVImageScannerRepository struct {
	exporter  *ImageExporter
	binary    string
	installer string
	install   sync.Once
	// installErr is why the installer failed, once it has run.
	installErr error
	slots      chan struct{}
	scans      sync.Map
}

// NewOSVImageScannerRepository builds the scanner. `binary` is the osv-scanner
// to run. `installer`, when set, runs the first time an image is actually
// scanned and leaves the pinned, checksum-verified scanner at `binary` -- so a
// run that scans no image, which is most pull requests, downloads nothing.
func NewOSVImageScannerRepository(transport Transport, binary, installer string) *OSVImageScannerRepository {
	return &OSVImageScannerRepository{
		exporter: NewImageExporter(transport), binary: binary, installer: installer,
		slots: make(chan struct{}, concurrentScans),
	}
}

// Scan scans one digest-pinned image, at most once per run.
func (r *OSVImageScannerRepository) Scan(reference string) (entities.ImageScan, error) {
	if cached, found := r.scans.Load(reference); found {
		scan, _ := cached.(entities.ImageScan)
		return scan, nil
	}
	if err := r.installOnce(); err != nil {
		return entities.ImageScan{}, repositories.NewLookupError(scanFailed, reference, err)
	}
	r.slots <- struct{}{}
	defer func() { <-r.slots }()
	scan, err := r.scan(reference)
	if err == nil {
		r.scans.Store(reference, scan)
	}
	return scan, err
}

// installOnce runs the installer, once per run, whichever scan needs it first.
func (r *OSVImageScannerRepository) installOnce() error {
	r.install.Do(func() {
		if r.installer == "" {
			return
		}
		ctx, cancel := context.WithTimeout(context.Background(), installTimeout)
		defer cancel()
		//nolint:gosec // G204: the installer is this command's own configuration, run with no argument
		command := exec.CommandContext(ctx, r.installer)
		var output bytes.Buffer
		command.Stdout, command.Stderr = &output, &output
		if err := command.Run(); err != nil {
			r.installErr = fmt.Errorf("installing osv-scanner with %s: %w: %s", r.installer, err, tail(output.String()))
		}
	})
	return r.installErr
}

func (r *OSVImageScannerRepository) scan(reference string) (entities.ImageScan, error) {
	directory, err := os.MkdirTemp("", "dependency-updates-image-")
	if err != nil {
		return entities.ImageScan{}, err
	}
	defer func() { _ = os.RemoveAll(directory) }()
	if err = r.exporter.Export(reference, filepath.Join(directory, "image.tar")); err != nil {
		var notScannable *NotScannableError
		if errors.As(err, &notScannable) {
			return entities.ImageScan{Reference: reference, Skipped: notScannable.Reason}, nil
		}
		return entities.ImageScan{}, err
	}
	report, err := r.run(directory)
	if err != nil {
		return entities.ImageScan{}, repositories.NewLookupError(scanFailed, reference, err)
	}
	findings, err := ParseImageScanReport(report)
	if err != nil {
		return entities.ImageScan{}, repositories.NewLookupError(scanFailed, reference, err)
	}
	return entities.ImageScan{Reference: reference, Findings: findings}, nil
}

func (r *OSVImageScannerRepository) run(directory string) ([]byte, error) {
	ctx, cancel := context.WithTimeout(context.Background(), scanTimeout)
	defer cancel()
	//nolint:gosec // G204: the scanner is this command's own configuration, every argument a constant
	command := exec.CommandContext(ctx, r.binary, "scan", "image", "--archive", "--format", "json",
		"--output-file", "scan.json", "--verbosity", "error", "image.tar")
	command.Dir = directory
	var stderr bytes.Buffer
	command.Stderr = &stderr
	err := command.Run()
	exitCode := 0
	var exit *exec.ExitError
	if errors.As(err, &exit) {
		exitCode = exit.ExitCode()
	}
	switch {
	case errors.Is(err, exec.ErrNotFound) || errors.Is(err, fs.ErrNotExist):
		return nil, fmt.Errorf("osv-scanner is not installed at %q; run.sh installs the pinned, checksum-verified one",
			r.binary)
	case exitCode == scannerFoundNoPackages:
		return []byte(`{"results": []}`), nil
	case err != nil && exitCode != scannerFoundVulnerabilities:
		return nil, errors.New(err.Error() + ": " + tail(stderr.String()))
	}
	return os.ReadFile(filepath.Join(directory, "scan.json"))
}

// tail is the end of a tool's output: where it says what went wrong.
func tail(output string) string {
	message := strings.TrimSpace(output)
	return message[max(0, len(message)-stderrTail):]
}

// ParseImageScanReport reads OSV-Scanner's JSON report into findings: one per
// group of identifiers OSV-Scanner reports as one issue of one package.
func ParseImageScanReport(content []byte) ([]entities.ImageFinding, error) {
	var report struct {
		Results []struct {
			Packages []struct {
				Package struct {
					Name      string `json:"name"`
					Version   string `json:"version"`
					Ecosystem string `json:"ecosystem"`
				} `json:"package"`
				Groups []struct {
					IDs         []string `json:"ids"`
					Aliases     []string `json:"aliases"`
					MaxSeverity string   `json:"max_severity"`
				} `json:"groups"`
			} `json:"packages"`
		} `json:"results"`
	}
	if err := json.Unmarshal(content, &report); err != nil {
		return nil, errors.New("not an OSV-Scanner report: " + err.Error())
	}
	var findings []entities.ImageFinding
	for _, result := range report.Results {
		for _, pkg := range result.Packages {
			for _, group := range pkg.Groups {
				identifiers := slices.Compact(
					slices.Sorted(slices.Values(append(slices.Clone(group.IDs), group.Aliases...))),
				)
				severity := entities.SeverityFromCVSS(group.MaxSeverity)
				if slices.ContainsFunc(identifiers, isMalwareIdentifier) {
					severity = entities.SeverityMalicious
				}
				findings = append(findings, entities.ImageFinding{
					Package: pkg.Package.Name, Version: pkg.Package.Version, Ecosystem: pkg.Package.Ecosystem,
					IDs: identifiers, Severity: severity,
				})
			}
		}
	}
	return findings, nil
}

// isMalwareIdentifier is an OSV malicious-package record, `MAL-<year>-<n>`.
func isMalwareIdentifier(identifier string) bool {
	return strings.HasPrefix(identifier, "MAL-")
}

// FixtureImageScannerRepository answers from a fixture's `scan:<reference>`
// entries: {"findings": [...], "skipped": "..."}. A reference with no entry is
// a failed scan, never a clean one.
type FixtureImageScannerRepository struct {
	fixture Fixture
}

// NewFixtureImageScannerRepository builds the offline scanner.
func NewFixtureImageScannerRepository(fixture Fixture) *FixtureImageScannerRepository {
	return &FixtureImageScannerRepository{fixture: fixture}
}

// Scan answers one image from the fixture.
func (r *FixtureImageScannerRepository) Scan(reference string) (entities.ImageScan, error) {
	raw, err := r.fixture.Answer("scan:" + reference)
	if err != nil {
		return entities.ImageScan{}, err
	}
	var answer struct {
		Skipped  string `json:"skipped"`
		Findings []struct {
			Package   string   `json:"package"`
			Version   string   `json:"version"`
			Ecosystem string   `json:"ecosystem"`
			IDs       []string `json:"ids"`
			Severity  string   `json:"severity"`
		} `json:"findings"`
	}
	if json.Unmarshal(raw, &answer) != nil {
		return entities.ImageScan{}, repositories.NewLookupError("fixture scan:%s is not a scan", reference)
	}
	scan := entities.ImageScan{Reference: reference, Skipped: answer.Skipped}
	for _, finding := range answer.Findings {
		scan.Findings = append(scan.Findings, entities.ImageFinding(finding))
	}
	return scan, nil
}
