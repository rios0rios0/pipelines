package main

import (
	"bytes"
	"maps"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// safetyTemplate is the declared consumer, mapping its key as it must.
const safetyTemplate = `stages:
  - stage: security
    jobs:
      - job: sca_safety
        steps:
          - script: |
              pdm run safety-scan
            displayName: 'Run Safety dependency check'
            env:
              SAFETY_API_KEY: $(SAFETY_API_KEY)
`

// repository lays out a minimal tree that satisfies the contract, plus `files`.
func repository(t *testing.T, files map[string]string) string {
	t.Helper()
	root := t.TempDir()
	all := map[string]string{
		"azure-devops/python/stages/20-security/pdm.yaml": safetyTemplate,
		"global/scripts/tools/upload/run.sh":              "#!/bin/sh\n# reads $UPLOAD_TOKEN\ncurl -H \"$UPLOAD_TOKEN\"\n",
		"azure-devops/global/upload.yaml": "steps:\n  - bash: $(Scripts.Directory)/global/scripts/tools/upload/run.sh\n" +
			"    displayName: Upload\n    env:\n      UPLOAD_TOKEN: $(UPLOAD_TOKEN)\n",
	}
	maps.Copy(all, files)
	for name, content := range all {
		path := filepath.Join(root, filepath.FromSlash(name))
		require.NoError(t, os.MkdirAll(filepath.Dir(path), 0o750))
		require.NoError(t, os.WriteFile(path, []byte(content), 0o600))
	}
	return root
}

// findings runs the check over root and returns its lines for one assertion.
func findings(t *testing.T, root, group string) []string {
	t.Helper()
	var output bytes.Buffer
	require.NoError(t, check(root, &output))
	var selected []string
	for line := range strings.SplitSeq(strings.TrimSuffix(output.String(), "\n"), "\n") {
		if name, finding, ok := strings.Cut(line, "\t"); ok && name == group {
			selected = append(selected, finding)
		}
	}
	return selected
}

func TestCheck(t *testing.T) {
	t.Parallel()

	t.Run("should report nothing when every credential travels through env", func(t *testing.T) {
		t.Parallel()
		// given
		root := repository(t, nil)

		// when
		var output bytes.Buffer
		err := check(root, &output)

		// then
		require.NoError(t, err)
		assert.Empty(t, output.String())
	})

	t.Run("should report a derived credential when a step runs a script reading it ambiently", func(t *testing.T) {
		t.Parallel()
		// given
		root := repository(t, map[string]string{
			"azure-devops/global/wrapped.yaml": "steps:\n  - ${{ if true }}:\n    - bash: " +
				"$(Scripts.Directory)/global/scripts/tools/upload/run.sh\n      displayName: \"Upload 'it'\"\n",
		})

		// when
		unmapped := findings(t, root, groupUnmapped)

		// then
		assert.Equal(t, []string{
			`azure-devops/global/wrapped.yaml: step "Upload 'it'" reads UPLOAD_TOKEN but never maps it through ` + "`env:`",
		}, unmapped)
	})

	t.Run("should report a credential when a task's inline script reads it ambiently", func(t *testing.T) {
		t.Parallel()
		// given
		root := repository(t, map[string]string{
			"azure-devops/global/task.yaml": "steps:\n  - task: AzureCLI@2\n    inputs:\n      inlineScript: |\n" +
				"        echo \"${DEPLOY_API_KEY}\"\n    displayName: Deploy\n    env:\n      DEPLOY_API_KEY: $(DEPLOY_API_KEY)\n" +
				"  - pwsh: Write-Host $env:X $OTHER_SECRET\n",
		})

		// when
		unmapped := findings(t, root, groupUnmapped)

		// then
		assert.Equal(t, []string{
			"azure-devops/global/task.yaml: step '<unnamed>' reads OTHER_SECRET but never maps it through `env:`",
		}, unmapped)
	})

	t.Run("should report the declared consumer when its step stops mapping the key", func(t *testing.T) {
		t.Parallel()
		// given
		root := repository(t, map[string]string{
			"azure-devops/python/stages/20-security/pdm.yaml": strings.Replace(
				safetyTemplate, "SAFETY_API_KEY: $(SAFETY_API_KEY)", "OTHER: x", 1),
		})

		// when
		unmapped := findings(t, root, groupUnmapped)

		// then
		assert.Equal(t, []string{
			"azure-devops/python/stages/20-security/pdm.yaml: step 'Run Safety dependency check' reads " +
				"SAFETY_API_KEY but never maps it through `env:`",
		}, unmapped)
	})

	t.Run("should report a stale declaration when the declared step no longer exists", func(t *testing.T) {
		t.Parallel()
		// given
		root := repository(t, map[string]string{
			"azure-devops/python/stages/20-security/pdm.yaml": strings.Replace(
				safetyTemplate, "Run Safety dependency check", "Run Safety (renamed)", 1),
		})

		// when
		classified := findings(t, root, groupClassified)

		// then
		assert.Equal(t, []string{
			"azure-devops/python/stages/20-security/pdm.yaml: no step named 'Run Safety dependency check' -- the " +
				"declared table names a step that no longer exists, so its credential is unchecked",
		}, classified)
	})

	t.Run(
		"should report an unclassified credential when a script mentions one nobody decided about",
		func(t *testing.T) {
			t.Parallel()
			// given
			root := repository(t, map[string]string{
				"global/scripts/shared/new.sh": "#!/bin/sh\n# BRAND_NEW_TOKEN is only explained here\necho \"$FRESH_PASSWORD\"\n",
			})

			// when
			classified := findings(t, root, groupClassified)

			// then
			assert.Equal(t, []string{
				thisSuite + ": FRESH_PASSWORD is credential-shaped but no Azure step maps it, and it is neither " +
					"declared nor exempt -- classify it so it cannot be passed ambiently by accident",
			}, classified)
		},
	)

	t.Run(
		"should report a macro when a script body spells a credential's macro, even in a comment",
		func(t *testing.T) {
			t.Parallel()
			// given
			root := repository(t, map[string]string{
				"azure-devops/global/doc.yaml": "steps:\n  - script: |\n      # needs $(UPLOAD_TOKEN)\n      echo ok\n" +
					"    displayName: Explain\n    env:\n      UPLOAD_TOKEN: $(UPLOAD_TOKEN)\n",
			})

			// when
			macro := findings(t, root, groupMacro)

			// then
			assert.Equal(t, []string{
				"azure-devops/global/doc.yaml: step 'Explain' spells $(UPLOAD_TOKEN) inside its script, so Azure " +
					"substitutes the credential's VALUE into the script text -- pass it through `env:` and read it as " +
					"a shell variable instead",
			}, macro)
		},
	)

	t.Run("should not report an exempt credential or an exempt step when they name one", func(t *testing.T) {
		t.Parallel()
		// given
		root := repository(t, map[string]string{
			"global/scripts/languages/dart/publish/run.sh": "#!/bin/sh\necho \"$PUB_TOKEN\"\n",
			"azure-devops/dart/stages/40-delivery/dart-library.yaml": "steps:\n  - bash: " +
				"global/scripts/languages/dart/publish/run.sh\n    displayName: 'Validate the package (dry run)'\n" +
				"  - bash: echo \"$SYSTEM_ACCESSTOKEN\"\n    env:\n      SYSTEM_ACCESSTOKEN: $(System.AccessToken)\n" +
				"  - bash: global/scripts/languages/dart/publish/run.sh\n    displayName: Publish\n" +
				"    env:\n      PUB_TOKEN: $(PUB_TOKEN)\n",
		})

		// when
		unmapped := findings(t, root, groupUnmapped)

		// then
		assert.Empty(t, unmapped)
	})

	t.Run("should report a template that does not parse when one is malformed", func(t *testing.T) {
		t.Parallel()
		// given
		root := repository(t, map[string]string{"azure-devops/broken.yaml": "steps: [\n"})

		// when
		parse := findings(t, root, groupParse)

		// then
		require.Len(t, parse, 1)
		assert.True(t, strings.HasPrefix(parse[0], "azure-devops/broken.yaml: yaml: line"), parse[0])
	})

	t.Run("should fail when the scripts directory is missing", func(t *testing.T) {
		t.Parallel()
		// given
		root := t.TempDir()

		// when
		err := check(root, &bytes.Buffer{})

		// then
		require.ErrorIs(t, err, os.ErrNotExist)
	})
}

func TestStepScript(t *testing.T) {
	t.Parallel()

	t.Run("should print the step's script when the job and displayName match", func(t *testing.T) {
		t.Parallel()
		// given
		path := filepath.Join(repository(t, nil), "azure-devops/python/stages/20-security/pdm.yaml")

		// when
		var output bytes.Buffer
		err := stepScript(path, "sca_safety", "Run Safety dependency check", &output)

		// then
		require.NoError(t, err)
		assert.Equal(t, "pdm run safety-scan\n", output.String())
	})

	t.Run("should print nothing when no job carries that name", func(t *testing.T) {
		t.Parallel()
		// given
		path := filepath.Join(repository(t, nil), "azure-devops/python/stages/20-security/pdm.yaml")

		// when
		var output bytes.Buffer
		err := stepScript(path, "sca_renamed", "Run Safety dependency check", &output)

		// then
		require.NoError(t, err)
		assert.Empty(t, output.String())
	})

	t.Run("should fail when the template has no stages list", func(t *testing.T) {
		t.Parallel()
		// given
		path := filepath.Join(t.TempDir(), "steps.yaml")
		require.NoError(t, os.WriteFile(path, []byte("steps: []\n"), 0o600))

		// when
		err := stepScript(path, "sca_safety", "Run Safety dependency check", &bytes.Buffer{})

		// then
		require.ErrorContains(t, err, "no `stages:` list")
	})
}

func TestRun(t *testing.T) {
	t.Parallel()

	t.Run("should print the usage and exit 2 when the arguments name no command", func(t *testing.T) {
		t.Parallel()
		// given
		var stdout, stderr bytes.Buffer

		// when
		status := run([]string{"other"}, &stdout, &stderr)

		// then
		assert.Equal(t, exitUsage, status)
		assert.Contains(t, stderr.String(), "usage:")
		assert.Empty(t, stdout.String())
	})

	t.Run("should exit 1 and say why when the template cannot be read", func(t *testing.T) {
		t.Parallel()
		// given
		var stdout, stderr bytes.Buffer
		missing := filepath.Join(t.TempDir(), "missing.yaml")

		// when
		status := run([]string{"step-script", missing, "job", "step"}, &stdout, &stderr)

		// then
		assert.Equal(t, exitFailed, status)
		assert.Contains(t, stderr.String(), "azuresecretenv: ")
	})
}
