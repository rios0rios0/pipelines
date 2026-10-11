package entities_test

import (
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/rios0rios0/pipelines/global/scripts/tools/dependency-updates/internal/domain/entities"
)

func TestParseManifest(t *testing.T) {
	t.Parallel()

	t.Run("should keep the pin annotations whichever order they come in", func(t *testing.T) {
		t.Parallel()
		// given
		manifest := "# checksums: https://example.test/v{version}/sums\n" +
			"# upstream: github-release owner/before\n" +
			"BEFORE_PINNED_VERSION=\"1.0.0\"\n\n" +
			"# upstream: github-release owner/after\n" +
			"# checksums: https://example.test/v{version}/sums\n" +
			"AFTER_PINNED_VERSION=\"1.0.0\"\n" +
			"AFTER_VERSION=\"${AFTER_VERSION:-${AFTER_PINNED_VERSION}}\"\n\n" +
			"# upstream: github-release owner/plain\n" +
			"PLAIN_PINNED_VERSION=\"1.0.0\"\n"

		// when
		entries := entities.ParseManifest(manifest)

		// then
		require.Len(t, entries, 3)
		assert.Equal(t, "https://example.test/v{version}/sums", entries[0].Checksums)
		assert.Equal(t, "https://example.test/v{version}/sums", entries[1].Checksums)
		assert.Empty(t, entries[2].Checksums, "an annotation never leaks onto the next pin")
	})

	t.Run("should read the security and vendoring annotations", func(t *testing.T) {
		t.Parallel()
		// given
		manifest := "# upstream: github-release maratori/golangci-lint-config ceiling=GOLANGCI_LINT cooldown=3\n" +
			"# vendored: global/scripts/languages/golang/golangci-lint/.golangci.yml\n" +
			"# osv: none\n" +
			"GOLANGCI_LINT_CONFIG_PINNED_VERSION=\"2.9.0\"\n" +
			"# asset: https://raw.githubusercontent.com/maratori/golangci-lint-config/v{version}/.golangci.yml\n" +
			"GOLANGCI_LINT_CONFIG_SHA256=\"" + sha("9") + "\"\n" +
			"# upstream: github-release gruntwork-io/terragrunt\n" +
			"# osv: Go github.com/gruntwork-io/terragrunt\n" +
			"TERRAGRUNT_PINNED_VERSION=\"1.1.6\"\n"

		// when
		entries := entities.ParseManifest(manifest)

		// then
		require.Len(t, entries, 2)
		config := entries[0]
		assert.Equal(t, "GOLANGCI_LINT", config.Ceiling)
		assert.True(t, config.HasCooldown)
		assert.Equal(t, 3, config.CooldownDays)
		assert.Equal(t, "global/scripts/languages/golang/golangci-lint/.golangci.yml", config.Vendored)
		require.NotNil(t, config.Advisories)
		assert.True(t, config.Advisories.None)
		require.Len(t, config.Digests, 1)
		assert.Contains(t, config.Digests[0].Asset, "{version}/.golangci.yml")
		require.NotNil(t, entries[1].Advisories)
		assert.Equal(t, entities.EcosystemGo, entries[1].Advisories.Ecosystem)
		assert.Equal(t, []string{"github.com/gruntwork-io/terragrunt"}, entries[1].Advisories.Packages)
	})

	t.Run("should read every package an advisory source names, and a minor line to track", func(t *testing.T) {
		t.Parallel()
		// given
		manifest := "# upstream: go-toolchain golang.org/toolchain track=1.27\n" +
			"# osv: Go stdlib toolchain\n" +
			"GO_PINNED_VERSION=\"1.27.2\"\n"

		// when
		entries := entities.ParseManifest(manifest)

		// then
		require.Len(t, entries, 1)
		assert.Equal(t, entities.KindGoToolchain, entries[0].Kind)
		assert.Equal(t, "1.27", entries[0].Track)
		require.NotNil(t, entries[0].Advisories)
		assert.Equal(t, []string{"stdlib", "toolchain"}, entries[0].Advisories.Packages)
	})

	t.Run("should give a digest to the pin with the longest matching name", func(t *testing.T) {
		t.Parallel()
		// given
		manifest := "# upstream: github-release golangci/golangci-lint\n" +
			"GOLANGCI_LINT_PINNED_VERSION=\"2.14.0\"\n" +
			"# upstream: github-release maratori/golangci-lint-config\n" +
			"GOLANGCI_LINT_CONFIG_PINNED_VERSION=\"2.9.0\"\n" +
			"GOLANGCI_LINT_CONFIG_SHA256=\"" + sha("a") + "\"\n"

		// when
		entries := entities.ParseManifest(manifest)

		// then
		assert.Empty(t, entries[0].Digests)
		require.Len(t, entries[1].Digests, 1)
		assert.Empty(t, entries[1].Digests[0].Asset, "a digest with no `# asset:` is reported, never guessed")
	})

	t.Run("should read a package spec and mark a pin with no upstream", func(t *testing.T) {
		t.Parallel()
		// given
		manifest := "# upstream: pypi pdm\n" +
			"PDM_SPEC=\"${PDM_SPEC:-pdm==2.29.2}\"\n" +
			"UNTRACKED_PINNED_VERSION=\"9.9.9\"\n"

		// when
		entries := entities.ParseManifest(manifest)

		// then
		require.Len(t, entries, 2)
		assert.Equal(t, entities.PinStyleSpec, entries[0].Style)
		assert.Equal(t, "2.29.2", entries[0].Current)
		assert.Equal(t, "pdm==2.29.2", entries[0].SpecValue)
		assert.Equal(t, entities.KindUnannotated, entries[1].Kind)
	})
}

func sha(character string) string {
	return strings.Repeat(character, 64)
}
