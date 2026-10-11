package cli

import (
	"io"
	"os"
	"strings"
	"time"

	"github.com/rios0rios0/pipelines/global/scripts/tools/dependency-updates/internal/domain/commands"
	"github.com/rios0rios0/pipelines/global/scripts/tools/dependency-updates/internal/domain/entities"
	"github.com/rios0rios0/pipelines/global/scripts/tools/dependency-updates/internal/domain/repositories"
	infrastructure "github.com/rios0rios0/pipelines/global/scripts/tools/dependency-updates/internal/infrastructure/repositories"
)

// container wires the commands to the network -- or to an offline fixture,
// which answers the same transport questions -- and to the scanned repository.
type container struct {
	workspace *infrastructure.FileWorkspaceRepository
	transport infrastructure.Transport
	fixture   infrastructure.Fixture
	settings  entities.Settings
	now       time.Time
	jobs      int
	// scanImages, scanner and installer are whether, and with which
	// osv-scanner, image rebuilds are scanned, and what installs it.
	scanImages bool
	scanner    string
	installer  string
}

func newContainer(
	root string,
	fixture infrastructure.Fixture,
	options runOptions,
	warnings io.Writer,
) (*container, error) {
	workspace, err := infrastructure.NewFileWorkspaceRepository(root)
	if err != nil {
		return nil, err
	}
	var transport infrastructure.Transport = infrastructure.NewHTTPTransport()
	if fixture != nil {
		transport = infrastructure.NewFixtureTransport(fixture)
	}
	settings, err := infrastructure.NewJSONSettingsRepository(workspace, warnings).Load()
	if err != nil {
		return nil, err
	}
	if options.cooldownDays >= 0 {
		settings.Cooldown, settings.HasCooldown = time.Duration(options.cooldownDays)*entities.Day, true
	}
	return &container{
		workspace: workspace, transport: transport, fixture: fixture, settings: settings,
		now: options.now, jobs: options.jobs,
		scanImages: options.scanImages, scanner: options.scanner, installer: options.installer,
	}, nil
}

func (c *container) close() {
	_ = c.workspace.Close()
}

func (c *container) advisories() repositories.AdvisoriesRepository {
	if c.fixture != nil {
		return infrastructure.NewFixtureAdvisoriesRepository(c.fixture)
	}
	return infrastructure.NewOSVAdvisoriesRepository(c.transport)
}

// imageScanner is nil when scanning is switched off; offline it answers from the
// fixture's `scan:` entries.
func (c *container) imageScanner() repositories.ImageScannerRepository {
	switch {
	case !c.scanImages:
		return nil
	case c.fixture != nil:
		return infrastructure.NewFixtureImageScannerRepository(c.fixture)
	default:
		return infrastructure.NewOSVImageScannerRepository(c.transport, c.scanner, c.installer)
	}
}

func (c *container) releases() *infrastructure.UpstreamReleasesRepository {
	return infrastructure.NewUpstreamReleasesRepository(c.transport, c.fixture)
}

func (c *container) checkCommand() *commands.CheckUpdatesCommand {
	return commands.NewCheckUpdatesCommand(c.workspace, c.releases(), c.advisories(), c.settings, c.now, c.jobs)
}

func (c *container) applyCommand() *commands.ApplyUpdatesCommand {
	return commands.NewApplyUpdatesCommand(
		c.workspace,
		infrastructure.NewReleaseArtifactsRepository(c.transport),
		infrastructure.NewGitHubSourceRepository(c.transport),
		infrastructure.NewGitMergeRepository(),
		c.imageScanner(),
		c.jobs,
	)
}

func (c *container) changelogCommand() *commands.RecordChangelogCommand {
	return commands.NewRecordChangelogCommand(
		c.workspace,
		infrastructure.NewGitHistoryRepository(c.workspace.Root()),
		c.now,
	)
}

func (c *container) verifyAssetsCommand() *commands.VerifyAssetsCommand {
	return commands.NewVerifyAssetsCommand(infrastructure.NewReleaseArtifactsRepository(c.transport))
}

func (c *container) verifyPullRequestCommand(
	base *infrastructure.FileWorkspaceRepository,
) *commands.VerifyPullRequestCommand {
	return commands.NewVerifyPullRequestCommand(commands.VerifyDependencies{
		Base: base, Head: c.workspace, Releases: c.releases(), Advisories: c.advisories(),
		Artifacts: infrastructure.NewReleaseArtifactsRepository(c.transport),
		Source:    infrastructure.NewGitHubSourceRepository(c.transport),
		Images:    infrastructure.NewRegistryImagesRepository(c.transport, c.fixture),
		Merger:    infrastructure.NewGitMergeRepository(),
		Scanner:   c.imageScanner(),
		Settings:  c.settings, Now: c.now, Jobs: c.jobs,
	})
}

func guardCommand(fixture infrastructure.Fixture) *commands.GuardPullRequestCommand {
	var transport infrastructure.Transport = infrastructure.NewHTTPTransport()
	if fixture != nil {
		transport = infrastructure.NewFixtureTransport(fixture)
	}
	// GitHub Enterprise Server answers on its own host; GitHub.com sets this too.
	api := strings.TrimRight(os.Getenv("GITHUB_API_URL"), "/")
	if api == "" {
		api = "https://api.github.com"
	}
	return commands.NewGuardPullRequestCommand(infrastructure.NewGitHubPullRequestsRepository(transport, api))
}
