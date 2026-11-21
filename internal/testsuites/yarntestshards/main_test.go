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

// defaultIf is the default job's condition before test sharding existed.
const defaultIf = "!cancelled() && !failure() && !startsWith(github.ref, 'refs/tags/')"

// defaultJob is the default `tests > test:all` with the given condition.
func defaultJob(condition string) string {
	return `  tests-test_all:
    name: 'tests > test:all'
    steps:
      - name: 'Checkout code'
        uses: 'actions/checkout@x'
      - name: 'Enable Corepack'
        run: 'corepack enable'
      - name: 'Setup Node.js'
        uses: 'actions/setup-node@x'
      - name: 'Export the build environment'
        if: "inputs.build_env != ''"
        run: 'printf x'
      - run: |
          yarn install
          yarn test:ci
        working-directory: "${{ inputs.working_directory }}"
      - name: 'Type check the end-to-end specs'
        if: 'inputs.e2e_typecheck'
        run: 'yarn e2e:typecheck'
      - name: 'Coverage Report'
        if: "always() && hashFiles(env.COVERAGE_SUMMARY_PATH) != ''"
        uses: 'x/coverage@x'
      - name: 'Test Results'
        if: "always() && hashFiles(env.JUNIT_REPORT_PATH) != ''"
        uses: 'x/results@x'
      - name: 'Upload Coverage Report'
        if: "always() && hashFiles(env.COVERAGE_INDEX_PATH) != ''"
        uses: 'actions/upload-artifact@x'
        continue-on-error: true
    needs: [ 'security-sast_x' ]
    if: "` + condition + `"
`
}

// fixture is the default job as the fixture holds it: before test sharding existed.
func fixture() string {
	return "jobs:\n" + defaultJob(defaultIf)
}

// baseWorkflow keeps the contract: the input, the default job with its one added condition, the
// shard matrix of three and their merge, each step where the checks expect it.
func baseWorkflow() string {
	return `on:
  workflow_call:
    inputs:
      test_shards:
        type: 'number'
        required: false
        default: 1
        description: 'Opt-in: from 1 to 3 jobs; above 1, require tests > test:all (merged).'
env:
  COVERAGE_DIR: "${{ inputs.working_directory }}/coverage"
jobs:
  security-sast_x:
    name: 'security > sast:x'
` + defaultJob(defaultIf+" && inputs.test_shards <= 1") + `  tests-test_all_shards:
    name: 'tests > test:all (shard ${{ matrix.shard }}/${{ inputs.test_shards }})'
    strategy:
      fail-fast: false
      matrix:
        shard: "${{ fromJSON('[[],[1],[1,2],[1,2,3]]')[inputs.test_shards] }}"
    steps:
      - name: 'Checkout code'
        uses: 'actions/checkout@x'
      - name: 'Enable Corepack'
        run: 'corepack enable'
      - name: 'Setup Node.js'
        uses: 'actions/setup-node@x'
      - name: 'Export the build environment'
        if: "inputs.build_env != ''"
        run: 'printf x'
      - name: 'Run the shard'
        run: |
          yarn install
          yarn test:ci:shard --shard="$SHARD/$TEST_SHARDS"
        working-directory: "${{ inputs.working_directory }}"
        env:
          INSTALL_RUN_SCRIPTS: "${{ inputs.install_run_scripts }}"
          SHARD: "${{ matrix.shard }}"
          TEST_SHARDS: "${{ inputs.test_shards }}"
      - name: 'Stage the coverage of the shard'
        run: 'cp coverage/coverage-final.json coverage/shards/'
        working-directory: "${{ inputs.working_directory }}"
        env:
          SHARD: "${{ matrix.shard }}"
      - name: 'Upload the coverage of the shard'
        uses: 'actions/upload-artifact@x'
        with:
          name: "coverage-shard-${{ matrix.shard }}"
          path: "${{ env.COVERAGE_DIR }}/shards/"
          if-no-files-found: 'error'
    needs: [ 'security-sast_x' ]
    if: "!cancelled() && !failure() && !startsWith(github.ref, 'refs/tags/') && inputs.test_shards > 1"
  tests-test_all_merged:
    name: 'tests > test:all (merged)'
    steps:
      - name: 'Checkout code'
        uses: 'actions/checkout@x'
      - name: 'Download the coverage of the shards'
        uses: 'actions/download-artifact@x'
        with:
          pattern: 'coverage-shard-*'
          merge-multiple: true
          path: "${{ env.COVERAGE_DIR }}/shards/"
      - name: 'Verify the shards'
        run: 'true'
        working-directory: "${{ inputs.working_directory }}"
        env:
          SHARDS_RESULT: "${{ needs.tests-test_all_shards.result }}"
          TEST_SHARDS: "${{ inputs.test_shards }}"
          TEST_SHARDS_MAX: '3'
      - name: 'Enable Corepack'
        run: 'corepack enable'
      - name: 'Setup Node.js'
        uses: 'actions/setup-node@x'
      - name: 'Export the build environment'
        if: "inputs.build_env != ''"
        run: 'printf x'
      - name: 'Merge the coverage of the shards'
        run: |
          yarn install
          yarn test:ci:merge
        working-directory: "${{ inputs.working_directory }}"
      - name: 'Remove the coverage of the shards'
        if: 'always()'
        run: 'rm -rf coverage/shards'
        working-directory: "${{ inputs.working_directory }}"
      - name: 'Type check the end-to-end specs'
        if: 'inputs.e2e_typecheck'
        run: 'yarn e2e:typecheck'
      - name: 'Coverage Report'
        if: "always() && hashFiles(env.COVERAGE_SUMMARY_PATH) != ''"
        uses: 'x/coverage@x'
      - name: 'Test Results'
        if: "always() && hashFiles(env.JUNIT_REPORT_PATH) != ''"
        uses: 'x/results@x'
      - name: 'Upload Coverage Report'
        if: "always() && hashFiles(env.COVERAGE_INDEX_PATH) != ''"
        uses: 'actions/upload-artifact@x'
        continue-on-error: true
    needs: [ 'security-sast_x', 'tests-test_all_shards' ]
    if: "!cancelled() && (!failure() || needs.tests-test_all_shards.result == 'failure') && !startsWith(github.ref, 'refs/tags/') && inputs.test_shards > 1"
  management-report_sonarqube:
    name: 'management > report:sonarqube'
    needs: [ 'tests-test_all' ]
`
}

// composedWorkflow is a workflow composed on yarn.yaml that declares the input and passes it on.
const composedWorkflow = `on:
  workflow_call:
    inputs:
      test_shards: {type: 'number', required: false, default: 1, description: 'See yarn.yaml.'}
jobs:
  yarn:
    uses: 'rios0rios0/pipelines/.github/workflows/yarn.yaml@main'
    with:
      test_shards: ${{ inputs.test_shards }}
`

const readme = "# Pipelines\n\n#### Splitting `test:all` Across Runners (`test_shards`)\n\n" +
	"It runs from 1 to 3 jobs: `tests > test:all (merged)` merges with `test:ci:merge` what `test:ci:shard` " +
	"left for each `--shard=<i>/<n>` under `coverage/shards/<i>/`, and the merge re-roots the paths. Name it " +
	"in `deployment_required_checks`; SonarQube does not wait for it.\n\n" +
	"#### The Next Section\n\nNothing here.\n"

const agents = "| Suite | What |\n|---|---|\n| `yarn-test-shards` | the shards |\n"

// repository lays out a tree that keeps the contract, then `files` over it.
func repository(t *testing.T, files map[string]string) string {
	t.Helper()
	root := t.TempDir()
	all := map[string]string{
		".github/workflows/yarn.yaml":               baseWorkflow(),
		".github/workflows/yarn-docker.yaml":        composedWorkflow,
		".github/tests/fixtures/yarn-test-all.yaml": fixture(),
		"README.md": readme,
		"AGENTS.md": agents,
	}
	maps.Copy(all, files)
	for name, content := range all {
		path := filepath.Join(root, filepath.FromSlash(name))
		require.NoError(t, os.MkdirAll(filepath.Dir(path), 0o750))
		require.NoError(t, os.WriteFile(path, []byte(content), 0o600))
	}
	return root
}

// mutated is `text` with each old string of the pairs replaced by the new one, the first time it
// occurs at or after `from`. A pair whose old string is not there fails the test: a mutation that
// changes nothing would pass for the wrong reason.
func mutated(t *testing.T, text, from string, pairs ...string) string {
	t.Helper()
	require.Zero(t, len(pairs)%2, "replacements come in pairs")
	start := strings.Index(text, from)
	require.GreaterOrEqual(t, start, 0, "no %q to mutate after", from)
	head, tail := text[:start], text[start:]
	for index := 0; index < len(pairs); index += 2 {
		require.Contains(t, tail, pairs[index])
		tail = strings.Replace(tail, pairs[index], pairs[index+1], 1)
	}
	return head + tail
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

	t.Run("should report nothing when the workflows keep the contract", func(t *testing.T) {
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

	t.Run("should report the input when it is mistyped, required, defaulted past one or not passed on",
		func(t *testing.T) {
			t.Parallel()
			// given
			root := repository(t, map[string]string{
				".github/workflows/yarn.yaml": mutated(t, baseWorkflow(), "on:", "type: 'number'", "type: 'string'",
					"required: false", "required: true", "default: 1", "default: 2"),
				".github/workflows/yarn-library.yaml": mutated(t, composedWorkflow, "jobs:",
					"      test_shards: ${{ inputs.test_shards }}\n", ""),
			})

			// when
			input := findings(t, root, "input")

			// then
			assert.Equal(t, []string{
				"yarn.yaml types `test_shards` as 'string', not 'number'",
				"yarn.yaml declares `test_shards` as required",
				"yarn.yaml defaults `test_shards` to 2, not 1, so a consumer that passes nothing no longer runs the " +
					"suite in one job",
				"yarn-library.yaml does not pass `test_shards` to yarn.yaml, so its consumers' value is dropped and " +
					"the suite runs in one job",
			}, input)
		})

	t.Run("should report the scan when no composed workflow calls yarn.yaml", func(t *testing.T) {
		t.Parallel()
		// given
		root := repository(t, map[string]string{
			".github/workflows/yarn-docker.yaml": mutated(t, composedWorkflow, "jobs:", "/yarn.yaml@main",
				"/npm.yaml@main"),
		})

		// when
		input := findings(t, root, "input")

		// then
		assert.Equal(t, []string{"no .github/workflows/yarn-*.yaml calls yarn.yaml -- the scan read nothing"}, input)
	})

	t.Run("should report the default job when it differs from the fixture in anything but its added condition",
		func(t *testing.T) {
			t.Parallel()
			// given
			root := repository(t, map[string]string{
				".github/workflows/yarn.yaml": mutated(t, baseWorkflow(), "  tests-test_all:",
					"          yarn test:ci\n", "          yarn test:ci --ci\n",
					"    needs: [ 'security-sast_x' ]", "    needs: [ 'security-sast_x', 'tests-test_all_shards' ]",
					" && inputs.test_shards <= 1\"", "\""),
			})

			// when
			drift := findings(t, root, "default")

			// then
			require.Len(t, drift, 3)
			assert.Contains(t, drift[0], "tests-test_all's `if` is not the default job's")
			assert.Contains(t, drift[1], "tests-test_all's `needs` is not the default job's")
			assert.Contains(t, drift[2], "tests-test_all's `steps` is not the default job's")
		})

	t.Run("should fail rather than report when the fixture is missing", func(t *testing.T) {
		t.Parallel()
		// given
		root := repository(t, nil)
		require.NoError(t, os.Remove(filepath.Join(root, fixturePath())))

		// when
		err := check(root, &bytes.Buffer{})

		// then
		require.Error(t, err)
	})

	t.Run("should report the names when two jobs share one or the merge stops waiting for what it merges",
		func(t *testing.T) {
			t.Parallel()
			// given
			root := repository(t, map[string]string{
				".github/workflows/yarn.yaml": mutated(t, baseWorkflow(), "  tests-test_all_shards:",
					"'tests > test:all (shard ${{ matrix.shard }}/${{ inputs.test_shards }})'",
					"'tests > test:all (merged)'",
					"needs: [ 'security-sast_x', 'tests-test_all_shards' ]", "needs: [ 'security-sast_x' ]",
					"needs: [ 'tests-test_all' ]", "needs: [ 'tests-test_all_merged' ]"),
			})

			// when
			jobs := findings(t, root, "jobs")

			// then
			assert.Equal(t, []string{
				"the jobs named 'tests > test:all (merged)' are [tests-test_all_shards tests-test_all_merged], not " +
					"tests-test_all_merged alone: two check runs of one name, one of them skipped, pass a required " +
					"check whatever the other did",
				"tests-test_all_shards is named 'tests > test:all (merged)', not 'tests > test:all (shard " +
					"${{ matrix.shard }}/${{ inputs.test_shards }})': each shard needs a check of its own",
				"tests-test_all_merged does not need tests-test_all_shards, so it can merge before " +
					"tests-test_all_shards has finished",
				"management-report_sonarqube (management > report:sonarqube) no longer needs tests-test_all",
			}, jobs)
		})

	t.Run("should report the matrix when it fails fast or its table is not 1..n", func(t *testing.T) {
		t.Parallel()
		// given
		failFast := repository(t, map[string]string{
			".github/workflows/yarn.yaml": mutated(t, baseWorkflow(), "  tests-test_all_shards:",
				"fail-fast: false", "fail-fast: true", "[1,2,3]]", "[1,3,2]]"),
		})
		unindexed := repository(t, map[string]string{
			".github/workflows/yarn.yaml": mutated(t, baseWorkflow(), "  tests-test_all_shards:",
				"[inputs.test_shards]", "[inputs.shards]"),
		})

		// when
		reported := findings(t, failFast, "matrix")
		unread := findings(t, unindexed, "matrix")

		// then
		assert.Equal(t, []string{
			"`fail-fast` is not false, so the first shard to fail cancels the others and their failures go " +
				"unreported until a re-run",
			"entry 3 of the shard table is [1 3 2], not the shards 1 to 3",
		}, reported)
		require.Len(t, unread, 1)
		assert.Contains(t, unread[0], "`shard` is not a table indexed by `inputs.test_shards`")
	})

	t.Run("should report the gates that skip the merge after a failed shard or run the default job sharded",
		func(t *testing.T) {
			t.Parallel()
			// given
			root := repository(t, map[string]string{
				".github/workflows/yarn.yaml": mutated(t, baseWorkflow(), "  tests-test_all:",
					" && inputs.test_shards <= 1\"", "\"",
					"(!failure() || needs.tests-test_all_shards.result == 'failure')", "!failure()"),
			})

			// when
			gates := findings(t, root, "gates")

			// then
			assert.Equal(t, []string{
				"tests-test_all runs when four shards are asked for",
				"tests-test_all_merged is skipped when a shard failed -- a skipped job would pass a required check",
				"tests-test_all_merged is skipped when no shard could start on a test_shards past the table",
			}, gates)
		})

	t.Run("should report a default job that reads the shards it does not need", func(t *testing.T) {
		t.Parallel()
		// given
		root := repository(t, map[string]string{
			".github/workflows/yarn.yaml": mutated(t, baseWorkflow(), "  tests-test_all:",
				" && inputs.test_shards <= 1\"", " && needs.tests-test_all_shards.result == 'skipped'\""),
		})

		// when
		gates := findings(t, root, "gates")

		// then
		require.NotEmpty(t, gates)
		assert.Equal(t, "tests-test_all: its `if:` reads `needs.tests-test_all_shards.result`, which no scenario of "+
			"this suite models", gates[0])
	})

	t.Run("should report the merged steps when they drift, skip a clean-up or run out of order", func(t *testing.T) {
		t.Parallel()
		// given
		drifted := repository(t, map[string]string{
			".github/workflows/yarn.yaml": mutated(t, baseWorkflow(), "  tests-test_all_merged:",
				"uses: 'actions/setup-node@x'", "uses: 'actions/setup-node@y'",
				"        if: 'always()'\n", "",
				"TEST_SHARDS_MAX: '3'", "TEST_SHARDS_MAX: '16'"),
		})
		download := "      - name: 'Download the coverage of the shards'\n" +
			"        uses: 'actions/download-artifact@x'\n" +
			"        with:\n          pattern: 'coverage-shard-*'\n          merge-multiple: true\n" +
			"          path: \"${{ env.COVERAGE_DIR }}/shards/\"\n"
		checkout := "      - name: 'Checkout code'\n        uses: 'actions/checkout@x'\n"
		reordered := repository(t, map[string]string{
			".github/workflows/yarn.yaml": mutated(t, baseWorkflow(), "  tests-test_all_merged:",
				checkout+download, download+checkout),
		})

		// when
		steps := findings(t, drifted, "steps")
		order := findings(t, reordered, "steps")

		// then
		assert.Equal(t, []string{
			"tests-test_all_merged does not run 'Setup Node.js' exactly as tests-test_all runs it",
			"tests-test_all_merged's 'Verify the shards' does not set TEST_SHARDS_MAX to '3'",
			"tests-test_all_merged's 'Remove the coverage of the shards' does not run after a failed step, so a " +
				"failed merge leaves the shards in the coverage artifact",
		}, steps)
		assert.Equal(t, []string{
			"tests-test_all_merged does not run the checkout, 'Download the coverage of the shards', 'Verify the " +
				"shards', the rest of the setup, 'Merge the coverage of the shards', 'Remove the coverage of the " +
				"shards' and the reports in that order",
		}, order)
	})

	t.Run("should report the shards when their setup or install drifts from the default job", func(t *testing.T) {
		t.Parallel()
		// given
		root := repository(t, map[string]string{
			".github/workflows/yarn.yaml": mutated(t, baseWorkflow(), "  tests-test_all_shards:",
				"run: 'corepack enable'", "run: 'corepack enable yarn'",
				"          yarn install\n          yarn test:ci:shard",
				"          npm ci\n          yarn test:ci:shard"),
		})

		// when
		steps := findings(t, root, "steps")

		// then
		assert.Equal(t, []string{
			"tests-test_all_shards does not run 'Enable Corepack' exactly as tests-test_all runs it",
			"tests-test_all_shards's 'Run the shard' does not install the dependencies as tests-test_all does",
		}, steps)
	})

	t.Run("should report the hand-off when it is optional, unmerged or names other artifacts", func(t *testing.T) {
		t.Parallel()
		// given
		root := repository(t, map[string]string{
			".github/workflows/yarn.yaml": mutated(t, baseWorkflow(), "  tests-test_all_shards:",
				"          if-no-files-found: 'error'\n", "          if-no-files-found: 'warn'\n        "+
					"continue-on-error: true\n",
				"pattern: 'coverage-shard-*'", "pattern: 'coverage-*'",
				"merge-multiple: true", "merge-multiple: false"),
		})

		// when
		handoff := findings(t, root, "handoff")

		// then
		assert.Equal(t, []string{
			"the artifact 'coverage-shard-${{ matrix.shard }}' is not one per shard that the pattern 'coverage-*' " +
				"downloads every one of",
			"the download does not set `merge-multiple`, so each shard lands under its artifact's name -- or, with " +
				"one artifact left, in the directory itself -- and not at coverage/shards/<i>/",
			"a shard that left no coverage uploads nothing and passes",
			"'Upload the coverage of the shard' may fail and pass its job, and the merge then judges a suite " +
				"that did not run in full",
		}, handoff)
	})

	t.Run("should report the documentation when it gives another range, drops a term or misses the suite",
		func(t *testing.T) {
			t.Parallel()
			// given
			root := repository(t, map[string]string{
				".github/workflows/yarn.yaml": mutated(t, baseWorkflow(), "on:", "from 1 to 3 jobs; above 1, require "+
					"tests > test:all (merged).", "from 1 to 16 jobs."),
				"README.md": mutated(t, readme, "#", "re-roots", "rewrites"),
				"AGENTS.md": "| Suite | What |\n",
			})

			// when
			docs := findings(t, root, "docs")

			// then
			assert.Equal(t, []string{
				"the description of `test_shards` does not say 'from 1 to 3'",
				"the description of `test_shards` does not say 'tests > test:all (merged)'",
				"README.md's (`test_shards`) section does not name re-roots",
				"AGENTS.md's suite table has no '| `yarn-test-shards` |' row",
			}, docs)
		})

	t.Run("should fail rather than report when yarn.yaml cannot be read", func(t *testing.T) {
		t.Parallel()
		// given
		root := repository(t, map[string]string{".github/workflows/yarn.yaml": "jobs: {a: 1}\njobs: {}\n"})

		// when
		err := check(root, &bytes.Buffer{})

		// then
		require.Error(t, err)
	})
}

func TestHolds(t *testing.T) {
	t.Parallel()

	properties := map[string]value{
		"inputs.shards": numberValue(fourShards),
		"inputs.empty":  textValue(""),
		"github.ref":    textValue("refs/tags/1.2.3"),
		"needs.a-b.out": textValue("failure"),
	}
	cases := []struct {
		condition string
		failed    bool
		want      bool
	}{
		{"inputs.shards > 1", false, true},
		{"inputs.shards > 1", true, false},                      // no status function: `success() &&` it
		{"failure() && needs.a-b.out == 'FAILURE'", true, true}, // strings compare ignoring case
		{"!cancelled() && (!failure() || inputs.shards <= 1)", true, false},
		{"${{ inputs.shards >= 4 && inputs.shards < 5 }}", false, true},
		{"!false == true", false, true}, // `!` binds tighter than `==`
		{"inputs.shards == '4'", false, true},
		{"null == 0", false, true},
		{"'a' < 'B'", false, true},
		{"'x' > 1 || 'x' <= 1", false, false}, // NaN orders nothing
		{"startsWith(github.ref, 'REFS/TAGS/')", false, true},
		{"inputs.empty || 'it''s'", false, true},
		{"", true, false},
		{"always()", true, true},
	}
	for _, testCase := range cases {
		t.Run("should read "+testCase.condition+" as GitHub does", func(t *testing.T) {
			t.Parallel()
			// given
			context := &scenario{properties: properties, failed: testCase.failed}

			// when
			got, err := holds(testCase.condition, context)

			// then
			require.NoError(t, err)
			assert.Equal(t, testCase.want, got)
		})
	}

	for _, condition := range []string{"github.event_name == 'push'", "fromJSON('1')", "inputs.list[0]",
		"'open", "inputs.shards >", "(inputs.shards", "inputs.shards = 1", "success(1)", "contains('a')"} {
		t.Run("should refuse rather than guess at "+condition, func(t *testing.T) {
			t.Parallel()
			// given
			context := &scenario{properties: properties}

			// when
			_, err := holds(condition, context)

			// then
			require.Error(t, err)
		})
	}
}

func TestRun(t *testing.T) {
	t.Parallel()

	t.Run("should print the table's end and a step's script", func(t *testing.T) {
		t.Parallel()
		// given
		root := repository(t, nil)
		var limit, script, stderr bytes.Buffer

		// when
		limitStatus := run([]string{"limit", root}, &limit, &stderr)
		scriptStatus := run([]string{"script", root, "tests-test_all_merged", "Remove the coverage of the shards"},
			&script, &stderr)

		// then
		assert.Equal(t, 0, limitStatus)
		assert.Equal(t, "3\n", limit.String())
		assert.Equal(t, 0, scriptStatus)
		assert.Equal(t, "rm -rf coverage/shards", script.String())
		assert.Empty(t, stderr.String())
	})

	t.Run("should fail by name when the step runs no script", func(t *testing.T) {
		t.Parallel()
		// given
		root := repository(t, nil)
		var stdout, stderr bytes.Buffer

		// when
		status := run([]string{"script", root, "tests-test_all_merged", "Coverage Report"}, &stdout, &stderr)

		// then
		assert.Equal(t, exitFailed, status)
		assert.Contains(t, stderr.String(), "tests-test_all_merged has no step 'Coverage Report' that runs a script")
	})

	t.Run("should answer usage when the command or its arguments are wrong", func(t *testing.T) {
		t.Parallel()
		// given
		var stdout, stderr bytes.Buffer

		// when
		unknown := run([]string{"verify", "."}, &stdout, &stderr)
		short := run([]string{"script", "."}, &stdout, &stderr)
		none := run(nil, &stdout, &stderr)

		// then
		assert.Equal(t, []int{exitUsage, exitUsage, exitUsage}, []int{unknown, short, none})
		assert.Empty(t, stdout.String())
	})
}
