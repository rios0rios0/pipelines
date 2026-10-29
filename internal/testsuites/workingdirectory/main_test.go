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

const declaredInput = "on:\n  workflow_call:\n    inputs:\n" +
	"      working_directory: {type: string, required: false, default: '.'}\n"

const threadedBase = declaredInput + `jobs:
  security-sast_semgrep:
    steps:
      - uses: 'x/semgrep@main'
  test:
    steps:
      - uses: 'actions/setup-node@abc'
        with:
          cache-dependency-path: '${{ inputs.working_directory }}/yarn.lock'
      - run: yarn install
        working-directory: "${{ inputs.working_directory }}"
      - name: 'Run SonarQube'
        run: "$SCRIPTS_DIR/global/scripts/tools/sonarqube/run.sh"
        env:
          SONAR_PROJECT_DIR: "${{ inputs.working_directory }}"
`

const threadedAction = `inputs:
  working_directory: {required: false, default: '.'}
runs:
  using: composite
  steps:
    - run: npm ci
      working-directory: "${{ inputs.working_directory }}"
    - uses: 'actions/upload-artifact@abc'
      with:
        path: "${{ inputs.working_directory }}/build/reports"
`

// repository lays out a tree that satisfies the contract, then `files` over it.
func repository(t *testing.T, files map[string]string) string {
	t.Helper()
	root := t.TempDir()
	all := map[string]string{
		"github/javascript/stages/10-code-check/format/action.yaml": threadedAction,
		"github/javascript/stages/10-code-check/knip/action.yaml":   threadedAction,
		"global/scripts/tools/sonarqube/run.sh":                     "#!/bin/sh\ncd \"$SONAR_PROJECT_DIR\"\n",
	}
	for workflow, base := range bases() {
		content := threadedBase
		if base != "" {
			content = declaredInput + "jobs:\n  base:\n    uses: rios0rios0/pipelines/.github/workflows/" + base +
				".yaml@main\n    with:\n      working_directory: \"${{ inputs.working_directory }}\"\n"
		}
		all[".github/workflows/"+workflow] = content
	}
	maps.Copy(all, files)
	for name, content := range all {
		path := filepath.Join(root, filepath.FromSlash(name))
		require.NoError(t, os.MkdirAll(filepath.Dir(path), 0o750))
		if content == "" {
			continue
		}
		require.NoError(t, os.WriteFile(path, []byte(content), 0o600))
	}
	return root
}

// findings checks root and returns its lines for one group.
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

	t.Run("should report nothing when every workflow and stage threads the input", func(t *testing.T) {
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

	t.Run("should report the declaration when the input is required, rooted elsewhere or mistyped", func(t *testing.T) {
		t.Parallel()
		// given
		root := repository(t, map[string]string{
			".github/workflows/npm.yaml": "on:\n  workflow_call:\n    inputs:\n" +
				"      working_directory: {type: number, required: true, default: 7}\njobs: {}\n",
			".github/workflows/yarn.yaml":                             "on:\n  workflow_call: {}\njobs: {}\n",
			"github/javascript/stages/10-code-check/knip/action.yaml": "",
		})

		// when
		declared := findings(t, root, "declared")

		// then
		assert.Equal(t, []string{
			"npm.yaml declares `working_directory` as required",
			"npm.yaml defaults `working_directory` to 7, not '.'",
			"npm.yaml types `working_directory` as 'number' rather than string",
			"yarn.yaml does not declare `working_directory`",
			"github/javascript/stages/10-code-check/knip/action.yaml is missing entirely",
		}, declared)
	})

	t.Run("should report a variant when it accepts the input and forwards nothing", func(t *testing.T) {
		t.Parallel()
		// given
		root := repository(t, map[string]string{
			".github/workflows/npm-docker.yaml": declaredInput +
				"jobs:\n  base:\n    uses: rios0rios0/pipelines/.github/workflows/npm.yaml@main\n",
		})

		// when
		forwarded := findings(t, root, "forwarded")

		// then
		assert.Equal(t, []string{"npm-docker.yaml does not pass `working_directory` to npm.yaml"}, forwarded)
	})

	t.Run("should report a repository-wide scan when it is scoped to the project", func(t *testing.T) {
		t.Parallel()
		// given
		root := repository(t, map[string]string{
			".github/workflows/yarn.yaml": declaredInput + "jobs:\n  security-sast_gitleaks:\n    steps:\n" +
				"      - uses: 'x/gitleaks@main'\n        with: {working_directory: app}\n",
		})

		// when
		scoped := findings(t, root, "repository_wide")

		// then
		assert.Equal(t, []string{
			"yarn.yaml :: security-sast_gitleaks :: step 0 scopes a repository-wide scan to the project",
		}, scoped)
	})

	t.Run("should report every project step when it runs in the workspace root", func(t *testing.T) {
		t.Parallel()
		// given
		root := repository(t, map[string]string{
			".github/workflows/bundler.yaml": declaredInput + `jobs:
  lint:
    steps:
      - uses: 'ruby/setup-ruby@abc'
        with:
          ruby-version: "${{ inputs.ruby_version || env.RUBY_VERSION_FILE || '3.3' }}"
      - uses: 'actions/setup-node@abc'
        with:
          cache-dependency-path: 'yarn.lock'
      - uses: 'rios0rios0/pipelines/github/javascript/stages/10-code-check/knip@main'
      - run: |
          echo first

          bundle exec rubocop
      - run: echo done || npm i -g corepack
`,
		})

		// when
		threaded := findings(t, root, "threaded")

		// then
		assert.Equal(t, []string{
			"bundler.yaml :: lint :: step 0: ruby/setup-ruby has no `working-directory`",
			"bundler.yaml :: lint :: step 1: actions/setup-node caches against the workspace root",
			"bundler.yaml :: lint :: step 2: 10-code-check/knip is called without `working_directory`",
			"bundler.yaml :: lint :: step 3: a project command runs in the workspace root: bundle exec rubocop",
		}, threaded)
	})

	t.Run("should report the Ruby version when it is hardcoded or read from .tool-versions", func(t *testing.T) {
		t.Parallel()
		// given
		root := repository(t, map[string]string{
			".github/workflows/bundler.yaml": declaredInput + `jobs:
  lint:
    steps:
      - uses: 'ruby/setup-ruby@abc'
        with:
          working-directory: "${{ inputs.working_directory }}"
          ruby-version: "${{ hashFiles('.tool-versions') != '' && 'default' || '3.3' }}"
`,
		})

		// when
		version := findings(t, root, "ruby_version")

		// then
		assert.Equal(t, []string{
			"bundler.yaml :: lint :: step 0: `ruby-version` does not reference inputs.ruby_version",
			"bundler.yaml :: lint :: step 0: `ruby-version` does not reference env.RUBY_VERSION_FILE",
			"bundler.yaml :: lint :: step 0: `ruby-version` infers `default` from `.tool-versions`, which says " +
				"nothing about a `ruby` entry being in it",
		}, version)
	})

	t.Run("should report report paths and guards when they are relative to the workspace root", func(t *testing.T) {
		t.Parallel()
		// given
		root := repository(t, map[string]string{
			".github/workflows/npm.yaml": declaredInput + `jobs:
  test:
    steps:
      - uses: 'dorny/test-reporter@abc'
        if: "always() && hashFiles('junit-report.xml') != ''"
        with:
          path: './coverage/'
          json-final-path: 5
`,
			"github/javascript/stages/10-code-check/format/action.yaml": strings.Replace(
				threadedAction, `"${{ inputs.working_directory }}/build/reports"`, "build/reports", 1),
		})

		// when
		paths := findings(t, root, "report_paths")

		// then
		assert.Equal(t, []string{
			"npm.yaml :: test :: step 0: `path: ./coverage/` is relative to the workspace root",
			"npm.yaml :: test :: step 0: a hashFiles() guard names a workspace-root path",
			"github/javascript/stages/10-code-check/format/action.yaml :: step 1: the report is uploaded from the " +
				"workspace root",
		}, paths)
	})

	t.Run("should report the Sonar scan when it is scoped or never told where the project is", func(t *testing.T) {
		t.Parallel()
		// given
		root := repository(t, map[string]string{
			".github/workflows/yarn.yaml": declaredInput + `jobs:
  sonar:
    steps:
      - run: "$SCRIPTS_DIR\\global\\scripts\\tools\\sonarqube\\run.sh"
        working-directory: app
`,
			"global/scripts/tools/sonarqube/run.sh": "#!/bin/sh\nsonar-scanner\n",
		})

		// when
		sonar := findings(t, root, "sonar")

		// then
		assert.Equal(t, []string{
			"yarn.yaml :: sonar :: step 0: the Sonar scan is scoped to the project, so it stops analysing the rest " +
				"of the repository",
			"yarn.yaml :: sonar :: step 0: the Sonar runner is not told where the project is (no `SONAR_PROJECT_DIR`), " +
				"so a subfolder project is read as having no coverage",
			"global/scripts/tools/sonarqube/run.sh ignores `SONAR_PROJECT_DIR`, so the workflows exporting it " +
				"change nothing",
		}, sonar)
	})

	t.Run("should fail when a workflow in scope does not parse", func(t *testing.T) {
		t.Parallel()
		// given
		root := repository(t, map[string]string{".github/workflows/npm.yaml": "jobs: [\n"})

		// when
		err := check(root, &bytes.Buffer{})

		// then
		require.ErrorContains(t, err, "npm.yaml")
	})
}

func TestRun(t *testing.T) {
	t.Parallel()

	t.Run("should print the usage and exit 2 when no repository root is given", func(t *testing.T) {
		t.Parallel()
		// given
		var stdout, stderr bytes.Buffer

		// when
		status := run(nil, &stdout, &stderr)

		// then
		assert.Equal(t, exitUsage, status)
		assert.Contains(t, stderr.String(), "usage:")
	})

	t.Run("should exit 0 and print the findings when the repository is checked", func(t *testing.T) {
		t.Parallel()
		// given
		root := repository(t, nil)
		var stdout, stderr bytes.Buffer

		// when
		status := run([]string{root}, &stdout, &stderr)

		// then
		assert.Equal(t, 0, status)
		assert.Empty(t, stdout.String())
		assert.Empty(t, stderr.String())
	})
}
