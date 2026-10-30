package entities_test

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/rios0rios0/pipelines/global/scripts/tools/dependency-updates/internal/domain/entities"
)

// scannerPin is the manifest a SonarQube scanner pin parses to.
func scannerPin(version string) []entities.ManifestEntry {
	return entities.ParseManifest("# upstream: github-release SonarSource/sonar-scanner-cli-docker\n" +
		"# osv: none\n# image: sonarsource/sonar-scanner-cli\n" +
		"SONAR_SCANNER_CLI_PINNED_VERSION=\"" + version + "\"\n")
}

func TestParseManifestImage(t *testing.T) {
	t.Parallel()

	t.Run("should read the image a pin is the tag of, and never lend it to the next pin", func(t *testing.T) {
		t.Parallel()
		// given
		text := "# upstream: github-release SonarSource/sonar-scanner-cli-docker\n# osv: none\n" +
			"# image: sonarsource/sonar-scanner-cli\nSONAR_SCANNER_CLI_PINNED_VERSION=\"12.1.0.3233_8.0.1\"\n\n" +
			"# upstream: github-release owner/next\n# osv: none\nNEXT_PINNED_VERSION=\"1.0.0\"\n"

		// when
		entries := entities.ParseManifest(text)

		// then
		require.Len(t, entries, 2)
		assert.Equal(t, "sonarsource/sonar-scanner-cli", entries[0].Image)
		assert.Equal(t, "12.1.0.3233_8.0.1", entries[0].Current)
		assert.Empty(t, entries[1].Image)
	})
}

func TestImagePin(t *testing.T) {
	t.Parallel()

	t.Run("should find the pin naming the image's repository, whatever its tag", func(t *testing.T) {
		t.Parallel()
		// given
		manifest := scannerPin("12.1.0.3233_8.0.1")

		// when
		pin := entities.ImagePin(manifest, "sonarsource/sonar-scanner-cli:12.3.0.4285_8.1.0@sha256:"+sha("a"))

		// then
		require.NotNil(t, pin)
		assert.Equal(t, "SONAR_SCANNER_CLI_PINNED_VERSION", pin.Var)
	})

	t.Run("should find no pin for another repository", func(t *testing.T) {
		t.Parallel()
		// given
		manifest := scannerPin("12.1.0.3233_8.0.1")

		// when
		mirror := entities.ImagePin(manifest, "registry.example:5000/sonarsource/sonar-scanner-cli:12.1.0.3233_8.0.1")
		longer := entities.ImagePin(manifest, "sonarsource/sonar-scanner-cli-extra:12.1.0.3233_8.0.1")

		// then
		assert.Nil(t, mirror)
		assert.Nil(t, longer)
	})
}

func TestFollowerName(t *testing.T) {
	t.Parallel()

	t.Run("should name the tag of the release, in the spelling the tag already has", func(t *testing.T) {
		t.Parallel()
		// given
		scanner := "sonarsource/sonar-scanner-cli:12.1.0.3233_8.0.1@sha256:" + sha("a")
		prefixed := "registry.example:5000/org/app:v1.2.3@sha256:" + sha("a")

		// when
		moved := entities.FollowerName(scanner, "12.2.0.4256_8.1.0")
		kept := entities.FollowerName(prefixed, "1.3.0")

		// then
		assert.Equal(t, "sonarsource/sonar-scanner-cli:12.2.0.4256_8.1.0", moved)
		assert.Equal(t, "registry.example:5000/org/app:v1.3.0", kept)
	})

	t.Run("should move a copy drifted to a rolling tag to the exact one", func(t *testing.T) {
		t.Parallel()
		// given
		rolling := "sonarsource/sonar-scanner-cli:12@sha256:" + sha("a")

		// when
		moved := entities.FollowerName(rolling, "12.1.0.3233_8.0.1")

		// then
		assert.Equal(t, "sonarsource/sonar-scanner-cli:12.1.0.3233_8.0.1", moved)
		assert.Equal(t, "12", entities.FollowerRelease(rolling))
	})

	t.Run("should keep a Go image's variant", func(t *testing.T) {
		t.Parallel()
		// given
		image := "golang:1.27.1-bookworm@sha256:" + sha("a")

		// when
		moved := entities.FollowerName(image, "1.27.2")

		// then
		assert.Equal(t, "golang:1.27.2-bookworm", moved)
		assert.Equal(t, "1.27.1", entities.FollowerRelease(image))
	})
}

func TestFindImagePinDrift(t *testing.T) {
	t.Parallel()

	t.Run("should report a copy tagged other than its pin, in whichever form it is written", func(t *testing.T) {
		t.Parallel()
		// given
		files := []entities.SourceText{
			{Path: "github.yaml", Text: "      image: 'sonarsource/sonar-scanner-cli:12.1.0.3233_8.0.1@sha256:" +
				sha("a") + "'\n"},
			{Path: "gitlab.yaml", Text: ".sonarqube:\n  image:\n    name: 'sonarsource/sonar-scanner-cli:12@sha256:" +
				sha("b") + "'\n    entrypoint: ['']\n"},
		}

		// when
		drifts := entities.FindImagePinDrift(files, scannerPin("12.1.0.3233_8.0.1"))

		// then
		require.Len(t, drifts, 1)
		assert.Equal(t, entities.Drift{
			Name: "SONAR_SCANNER_CLI_PINNED_VERSION", File: "gitlab.yaml",
			Inline: "sonarsource/sonar-scanner-cli:12", Manifest: "12.1.0.3233_8.0.1",
		}, drifts[0])
	})

	t.Run("should judge nothing when no pin names an image", func(t *testing.T) {
		t.Parallel()
		// given
		files := []entities.SourceText{{Path: "a.yaml", Text: "image: 'sonarsource/sonar-scanner-cli:12@sha256:" +
			sha("a") + "'\n"}}
		manifest := entities.ParseManifest("# upstream: github-release owner/tool\n# osv: none\n" +
			"TOOL_PINNED_VERSION=\"1.0.0\"\n")

		// when
		drifts := entities.FindImagePinDrift(files, manifest)

		// then
		assert.Empty(t, drifts)
	})
}
