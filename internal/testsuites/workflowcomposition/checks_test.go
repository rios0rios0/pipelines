package main

import (
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
)

// reviewWorkflowText is a review workflow whose guard skips exactly the automation pull requests.
func reviewWorkflowText(guard string) string {
	return `on:
  workflow_call:
    inputs:
      runs_on:
        type: string
        required: false
        default: '["ubuntu-latest"]'
      autoupdate_branch_prefix:
        type: string
        required: false
        default: 'chore/autoupdate-'
jobs:
  claude-review:
    if: >-
` + guard + `
    runs-on: ${{ fromJSON(inputs.runs_on) }}
`
}

func completeGuard() string {
	return `      github.event.pull_request.head.repo.full_name == github.repository
      && github.event.pull_request.draft == false
      && !startsWith(github.event.pull_request.head.ref, 'chore/bump-')
      && !startsWith(github.event.pull_request.head.ref, 'bump/')
      && !startsWith(github.event.pull_request.head.ref, 'dependabot/')
      && !(inputs.autoupdate_branch_prefix != ''
      && startsWith(github.event.pull_request.head.ref, inputs.autoupdate_branch_prefix))`
}

func TestCheckRunsOn(t *testing.T) {
	t.Parallel()

	t.Run("should report nothing when every job resolves its runner from runs_on", func(t *testing.T) {
		t.Parallel()
		// given
		directory := workflows(t, claudeWorkflows())

		// when
		found := findings(t, checkRunsOn, directory)

		// then
		assert.Empty(t, found)
	})

	t.Run("should report a pinned runner as Python would print it when a job hardcodes one", func(t *testing.T) {
		t.Parallel()
		// given
		directory := workflows(t, withFiles(claudeWorkflows(), map[string]string{
			"go.yaml": "on:\n  workflow_call:\n    inputs:\n      runs_on:\n        required: false\n" +
				"        default: '[\"ubuntu-latest\"]'\njobs:\n  a:\n    runs-on: [self-hosted, linux]\n",
		}))

		// when
		found := findings(t, checkRunsOn, directory)

		// then
		assert.Equal(t, []string{
			"go.yaml: job a pins a runner instead of resolving one from an input (['self-hosted', 'linux'])",
		}, found)
	})

	t.Run("should report a reusable caller that drops runs_on when its callee takes it", func(t *testing.T) {
		t.Parallel()
		// given
		directory := workflows(t, withFiles(claudeWorkflows(), map[string]string{
			"go.yaml": "on:\n  workflow_call:\n    inputs:\n      runs_on:\n        required: false\n" +
				"        default: '[\"ubuntu-latest\"]'\njobs:\n  a:\n    runs-on: ${{ fromJSON(inputs.runs_on) }}\n",
			"go-docker.yaml": "on: [workflow_call]\njobs:\n  go:\n    uses: './.github/workflows/go.yaml'\n",
		}))

		// when
		found := findings(t, checkRunsOn, directory)

		// then
		assert.Equal(t, []string{
			"go-docker.yaml: job go calls a workflow that takes runs_on, but go-docker.yaml declares no runs_on " +
				"of its own to forward -- its consumers cannot reach another runner",
		}, found)
	})

	t.Run("should report the missing Claude reusables when none is left to read", func(t *testing.T) {
		t.Parallel()
		// given
		directory := workflows(t, map[string]string{"ci.yaml": "on: push\njobs: {}\n"})

		// when
		found := findings(t, checkRunsOn, directory)

		// then
		assert.Equal(t, []string{"no reusable-claude-*.yaml in .github/workflows/ -- renamed, or removed"}, found)
	})
}

func TestCheckTrigger(t *testing.T) {
	t.Parallel()

	t.Run("should report nothing when every clause pairs its association with its payload", func(t *testing.T) {
		t.Parallel()
		// given
		directory := workflows(t, claudeWorkflows())

		// when
		found := findings(t, checkTrigger, directory)

		// then
		assert.Empty(t, found)
	})

	t.Run("should report the thread author's association when a comment payload reaches it", func(t *testing.T) {
		t.Parallel()
		// given
		directory := workflows(t, map[string]string{
			mentionWorkflow: "jobs:\n  claude:\n    if: (github.event.issue != null && " +
				"contains(fromJSON('[\"OWNER\",\"MEMBER\",\"COLLABORATOR\"]'), github.event.issue.author_association))\n",
		})

		// when
		found := findings(t, checkTrigger, directory)

		// then
		assert.Equal(t, []string{
			mentionWorkflow + ": job claude reads the THREAD AUTHOR association on a clause that an issue_comment " +
				"payload also reaches -- it carries both `comment` and `issue`",
		}, found)
	})
}

func TestCheckOnExpressions(t *testing.T) {
	t.Parallel()

	t.Run("should report every evaluated description or default when the trigger block has them", func(t *testing.T) {
		t.Parallel()
		// given
		directory := workflows(t, map[string]string{
			"deploy.yaml": "on:\n  workflow_call:\n    inputs:\n      app:\n" +
				"        description: 'e.g. ${{ github.ref }}'\n        default: plain\n" +
				"  workflow_dispatch:\n    inputs:\n      ref:\n        default: '${{ github.ref_name }}'\n",
		})

		// when
		found := findings(t, checkOnExpressions, directory)

		// then
		assert.Equal(t, []string{
			"deploy.yaml: on.workflow_call.inputs.app.description contains an evaluated expression",
			"deploy.yaml: on.workflow_dispatch.inputs.ref.default contains an evaluated expression",
		}, found)
	})
}

func TestCheckClaudeTools(t *testing.T) {
	t.Parallel()

	t.Run("should report a prompt that would select agent mode when track_progress is off", func(t *testing.T) {
		t.Parallel()
		// given
		directory := workflows(t, map[string]string{
			"reusable-claude-review.yaml": "jobs:\n  review:\n    steps:\n      - uses: 'anthropics/claude-code-action@abc'\n" +
				"        with:\n          prompt: |\n            Tools: `git add`, `git commit` and `git rm`.\n\n" +
				"            Denied on purpose: `go`.\n",
		})

		// when
		found := findings(t, checkClaudeTools, directory)

		// then
		assert.Equal(t, []string{
			"reusable-claude-review.yaml: declares a prompt without `track_progress: true` -- a prompt on a comment " +
				"or issue event selects AGENT mode, replacing the template that answers the trigger",
		}, found)
	})
}

func TestCheckReviewGuard(t *testing.T) {
	t.Parallel()

	t.Run("should report nothing when the guard skips exactly the automation pull requests", func(t *testing.T) {
		t.Parallel()
		// given
		directory := workflows(t, map[string]string{reviewWorkflow: reviewWorkflowText(completeGuard())})

		// when
		found := findings(t, checkReviewGuard, directory)

		// then
		assert.Empty(t, found)
	})

	t.Run("should report the pull request a dropped prefix lets through", func(t *testing.T) {
		t.Parallel()
		// given
		guard := strings.Replace(completeGuard(),
			"      && !startsWith(github.event.pull_request.head.ref, 'dependabot/')\n", "", 1)
		directory := workflows(t, map[string]string{reviewWorkflow: reviewWorkflowText(guard)})

		// when
		found := findings(t, checkReviewGuard, directory)

		// then
		assert.Equal(t, []string{
			reviewWorkflow + ": a dependabot bump (dependabot/github_actions/x) is reviewed, but it must not be",
		}, found)
	})
}

func TestCheckCancelGate(t *testing.T) {
	t.Parallel()

	t.Run("should report the clause a cancelled run still starts", func(t *testing.T) {
		t.Parallel()
		// given
		directory := workflows(t, map[string]string{
			"go-docker.yaml": "jobs:\n  delivery:\n    if: \"!failure() && github.ref == 'refs/heads/main'\"\n" +
				"  guarded:\n    if: \"!cancelled() && !failure()\"\n",
		})

		// when
		found := findings(t, checkCancelGate, directory)

		// then
		assert.Equal(t, []string{
			"go-docker.yaml: job delivery still starts on a cancelled run -- `!failure() && github.ref == " +
				"'refs/heads/main'` has no `!cancelled()` or `success()` of its own; write `!cancelled() && " +
				"!failure() && (...)`",
		}, found)
	})

	t.Run("should report a scan that read nothing when no job calls a status function", func(t *testing.T) {
		t.Parallel()
		// given
		directory := workflows(t, map[string]string{"ci.yaml": "jobs:\n  a:\n    if: github.ref == 'x'\n"})

		// when
		found := findings(t, checkCancelGate, directory)

		// then
		assert.Equal(t, []string{"no job under " + directory + " gates on a status function -- the scan read nothing"},
			found)
	})
}

func TestCheckAdvisoryJobs(t *testing.T) {
	t.Parallel()

	t.Run("should report an unlisted check job when it carries continue-on-error", func(t *testing.T) {
		t.Parallel()
		// given
		directory := workflows(t, map[string]string{
			"go.yaml": "jobs:\n  code_check-style_lint:\n    continue-on-error: ${{ inputs.advisory }}\n",
		})

		// when
		found := findings(t, checkAdvisoryJobs, directory)

		// then
		assert.Contains(t, found, "go.yaml: job code_check-style_lint is advisory -- its job-level "+
			"`continue-on-error` passes the run whatever the check finds. Remove it (a refused upload is "+
			"tolerated at the upload step), or list the job in ADVISORY with the reason it may stay advisory")
		assert.Contains(t, found, "npm.yaml: job code_check-style_eslint is listed as advisory but is not -- "+
			"remove the entry")
	})
}

func TestCheckAdvisoryTwins(t *testing.T) {
	t.Parallel()

	t.Run("should report a GitLab job that may fail when it carries allow_failure", func(t *testing.T) {
		t.Parallel()
		// given
		root := tree(t, map[string]string{
			"gitlab/golang/stages/10-code-check/go.yaml": "style:golangci-lint:\n  script: [ run ]\n" +
				"  allow_failure:\n    exit_codes: [ 4 ]\n",
			"gitlab/golang/stages/20-security/go.yaml": "sca:govulncheck:\n  script: [ run ]\n",
			"azure-devops/golang/stages/10-code-check/go.yaml": "stages:\n  - stage: code_check\n    jobs:\n" +
				"      - job: style_golangci_lint\n",
			"azure-devops/golang/stages/20-security/go.yaml": "jobs:\n  - job: sca_govulncheck\n",
		})

		// when
		found := findings(t, checkAdvisoryTwins, root)

		// then
		assert.Contains(t, found, "gitlab/golang/stages/10-code-check/go.yaml: job style:golangci-lint is "+
			"`allow_failure` -- a failure passes the pipeline; remove it, or list it in GITLAB_ADVISORY with its reason")
		assert.NotContains(t, strings.Join(found, "\n"), "no job sca:govulncheck found")
	})
}

func TestCheckPackagesGrant(t *testing.T) {
	t.Parallel()

	t.Run("should report a job handed an image when its permissions leave packages out", func(t *testing.T) {
		t.Parallel()
		// given
		directory := workflows(t, map[string]string{
			"go-flyio.yaml": "jobs:\n  deploy:\n    permissions: {contents: read}\n    steps:\n" +
				"      - with: {image: '${{ needs.docker.outputs.image }}'}\n" +
				"  granted:\n    permissions: {packages: read}\n    steps:\n" +
				"      - with: {image: '${{ needs.docker.outputs.image }}'}\n",
		})

		// when
		found := findings(t, checkPackagesGrant, directory)

		// then
		assert.Equal(t, []string{
			"go-flyio.yaml: job deploy is handed a delivered image, but its `permissions:` grant no `packages` -- " +
				"add `packages: read`, or its token cannot pull a private image",
		}, found)
	})
}

// stagedWorkflow is a two-stage workflow whose security job needs `needs` and gates on `condition`,
// behind a changelog gate that runs on pull requests only.
func stagedWorkflow(needs, condition string) string {
	return "jobs:\n" +
		"  basic:\n    name: 'code-check > quality:basic-checks'\n    if: \"github.event_name == 'pull_request'\"\n" +
		"  lint:\n    name: 'code-check > style:lint'\n" +
		"  scan:\n    name: 'security > sast:scan'\n    needs: " + needs + "\n    if: \"" + condition + "\"\n"
}

func TestCheckStageBarrier(t *testing.T) {
	t.Parallel()

	tolerant, implicit := "!cancelled() && !failure()", "!startsWith(github.ref, 'refs/tags/')"
	cases := []struct {
		name     string
		files    map[string]string
		expected []string
	}{
		{
			name:  "should report nothing when every stage waits for the whole stage before it",
			files: map[string]string{"go.yaml": stagedWorkflow("[ basic, lint ]", tolerant)},
		},
		{
			name:  "should report a job that can start before part of the stage before it finishes",
			files: map[string]string{"go.yaml": stagedWorkflow("[ lint ]", tolerant)},
			expected: []string{"go.yaml: job scan (security > sast:scan) can start before basic " +
				"(code-check > quality:basic-checks) finishes -- add it to `needs:`, so each stage waits for the " +
				"whole stage before it"},
		},
		{
			name:  "should report a job behind a skippable check that keeps the implicit success()",
			files: map[string]string{"go.yaml": stagedWorkflow("[ basic, lint ]", implicit)},
			expected: []string{"go.yaml: job scan needs basic, which can be skipped, and its `if:` calls no status " +
				"function, so GitHub skips it too whenever basic is skipped -- gate it on " +
				"`!cancelled() && !failure() && (...)`"},
		},
		{
			name: "should report a delivery job that does not wait for the pipeline it ships",
			files: map[string]string{"go-docker.yaml": "jobs:\n" +
				"  go:\n    uses: 'rios0rios0/pipelines/.github/workflows/go.yaml@main'\n" +
				"  docker:\n    name: 'delivery > docker'\n"},
			expected: []string{"go-docker.yaml: job docker (delivery > docker) can start before go () finishes -- " +
				"add it to `needs:`, so each stage waits for the whole stage before it"},
		},
		{
			name: "should let a skip below the checking stages propagate on purpose",
			files: map[string]string{"release.yaml": "jobs:\n" +
				"  release:\n    name: 'delivery > release'\n    if: \"github.event_name == 'push'\"\n" +
				"  tag:\n    name: 'delivery > tag'\n    needs: [ release ]\n"},
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			// given
			directory := workflows(t, tc.files)

			// when
			found := findings(t, checkStageBarrier, directory)

			// then
			assert.Equal(t, tc.expected, found)
		})
	}

	t.Run("should report a scan that read no staged job", func(t *testing.T) {
		t.Parallel()
		// given
		directory := workflows(t, map[string]string{"empty.yaml": "jobs:\n  a:\n    runs-on: ubuntu-latest\n"})

		// when
		found := findings(t, checkStageBarrier, directory)

		// then
		assert.Equal(t, []string{
			"no job under " + directory + " is named for a stage -- the scan read nothing",
		}, found)
	})
}
