package entities_test

import (
	"testing"
	"time"

	"github.com/stretchr/testify/assert"

	"github.com/rios0rios0/pipelines/global/scripts/tools/dependency-updates/internal/domain/entities"
)

const goldenBase = `version: "2"

formatters:
  enable:
    - goimports # checks imports
    - golines # fixes long lines

linters:
  enable:
    - asasalint # checks variadic any
    - bodyclose # closes bodies

    ## disabled
    #- paralleltest # [too many false positives]

  settings:
    funlen:
      lines: 100
`

const goldenNext = `version: "2"

formatters:
  enable:
    - goimports # checks imports
    - golines # fixes long lines

linters:
  enable:
    - asasalint # checks variadic any
    - paralleltest # detects missing t.Parallel()

  settings:
    funlen:
      lines: 100
`

func TestLinterChanges(t *testing.T) {
	t.Parallel()

	t.Run("should report what a new release switches on and off", func(t *testing.T) {
		t.Parallel()
		// given
		base, next := goldenBase, goldenNext

		// when
		switchedOn, switchedOff := entities.LinterChanges(base, next)

		// then
		assert.Equal(t, []string{"paralleltest"}, switchedOn)
		assert.Equal(t, []string{"bodyclose"}, switchedOff)
	})

	t.Run("should list formatters as formatters", func(t *testing.T) {
		t.Parallel()
		// given / when
		enabled := entities.EnabledLinters(goldenBase)

		// then
		assert.Equal(t, []string{"goimports (formatter)", "golines (formatter)", "asasalint", "bodyclose"}, enabled)
	})
}

func TestDeclaresPlugin(t *testing.T) {
	t.Parallel()

	t.Run("should notice a custom linter plugin", func(t *testing.T) {
		t.Parallel()
		// given
		configuration := goldenNext + "    custom:\n      evil:\n        path: ./evil.so\n"

		// when / then
		assert.True(t, entities.DeclaresPlugin(configuration))
		assert.False(t, entities.DeclaresPlugin(goldenNext))
	})
}

func TestInsertUnreleasedEntry(t *testing.T) {
	t.Parallel()

	changelog := "# Changelog\n\n## [Unreleased]\n\n### Added\n\n- added something earlier\n\n" +
		"## [1.0.0] - 2026-01-15\n\n### Changed\n\n- changed something released\n"

	t.Run("should add the section under Unreleased without touching what was released", func(t *testing.T) {
		t.Parallel()
		// given / when
		updated, found := entities.InsertUnreleasedEntry(changelog, entities.ChangelogSecurity, "fixed GHSA-x")

		// then
		assert.True(t, found)
		assert.Contains(t, updated, "## [Unreleased]\n\n### Security\n\n- fixed GHSA-x\n\n### Added")
		assert.Contains(t, updated, "## [1.0.0] - 2026-01-15\n\n### Changed\n\n- changed something released\n")
	})

	t.Run("should add to an existing section", func(t *testing.T) {
		t.Parallel()
		// given / when
		updated, found := entities.InsertUnreleasedEntry(changelog, "Added", "added another")

		// then
		assert.True(t, found)
		assert.Contains(t, updated, "### Added\n\n- added another\n- added something earlier\n")
	})

	t.Run("should report a changelog with nowhere to add it", func(t *testing.T) {
		t.Parallel()
		// given / when
		_, found := entities.InsertUnreleasedEntry("# Changelog\n", entities.ChangelogChanged, "x")

		// then
		assert.False(t, found)
	})
}

func TestFragment(t *testing.T) {
	t.Parallel()

	t.Run("should be named and stamped the way chlog names its own", func(t *testing.T) {
		t.Parallel()
		// given
		when := time.Date(2026, 10, 8, 6, 0, 0, 0, time.UTC)

		// when
		name := entities.FragmentName(when, sha("e"), 1)
		content := entities.FragmentContent(entities.ChangelogSecurity, "fixed it's thing", when)

		// then
		assert.Equal(t, ".changes/unreleased/1791439200000000000-eeee.yaml", name)
		assert.Equal(
			t,
			"kind: 'Security'\nbody: 'fixed it''s thing'\ntime: '2026-10-08T06:00:00.000000000Z'\n",
			content,
		)
	})
}

func TestMatchesAny(t *testing.T) {
	t.Parallel()

	t.Run("should let a star cross a slash, as fnmatch does", func(t *testing.T) {
		t.Parallel()
		// given / when
		owner := entities.MatchesAny("rios0rios0/terra", []string{"rios0rios0/*"})
		suffix := entities.MatchesAny("actions/checkout", []string{"*checkout"})
		image := entities.MatchesAny("someimage:1.0", []string{"someimage*"})
		other := entities.MatchesAny("otherimage:2.0", []string{"someimage*"})

		// then
		assert.True(t, owner)
		assert.True(t, suffix)
		assert.True(t, image)
		assert.False(t, other)
	})
}
