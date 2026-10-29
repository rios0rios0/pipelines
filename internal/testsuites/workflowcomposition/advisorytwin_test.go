package main

import (
	"testing"

	"github.com/stretchr/testify/assert"
)

// twinTree is the Go stages of both platforms, the Azure security stage pulling its jobs from a
// shared template, with the given files written over them.
func twinTree(t *testing.T, extra map[string]string) string {
	t.Helper()
	return tree(t, withFiles(map[string]string{
		"gitlab/golang/stages/10-code-check/go.yaml": "include:\n" +
			"  - remote: 'https://raw.githubusercontent.com/rios0rios0/pipelines/main/gitlab/global/stages/" +
			"20-security/semgrep.yaml'\n  - remote: 'https://example.com/elsewhere/stages/x.yaml'\n" +
			"style:golangci-lint:\n  script: [ run ]\n",
		"gitlab/global/stages/20-security/semgrep.yaml": ".scripts-repo:\n  allow_failure: true\n" +
			"sast:semgrep:\n  before_script:\n    - !reference [ .scripts-repo, before_script ]\n",
		"gitlab/golang/stages/20-security/go.yaml": "sca:govulncheck:\n  script: [ run ]\n",
		"azure-devops/golang/stages/10-code-check/go.yaml": "stages:\n  - stage: code_check\n    jobs:\n" +
			"      - job: style_golangci_lint\n        steps:\n" +
			"          - script: global/scripts/languages/golang/cache-trim/run.sh\n" +
			"            displayName: 'Trim the Go build cache when the agent is low on disk'\n" +
			"            continueOnError: true\n",
		"azure-devops/golang/stages/20-security/go.yaml": "stages:\n  - stage: security\n    jobs:\n" +
			"      - template: '../../../global/stages/20-security/semgrep.yaml'\n" +
			"      - template: '../../../global/stages/20-security/semgrep.yaml'\n" +
			"      - job: sca_govulncheck\n",
		"azure-devops/global/stages/20-security/semgrep.yaml": "jobs:\n  - job: sast_semgrep\n    steps:\n" +
			"      - task: 'PublishPipelineArtifact@1'\n        continueOnError: true\n" +
			"      - script: |\n          cd x\n          global/scripts/tools/semgrep/run.sh --all\n" +
			"        continueOnError: true\n",
	}, extra))
}

func TestCheckAdvisoryTwinsTemplates(t *testing.T) {
	t.Parallel()

	t.Run("should excuse the listed steps when the templates they sit in are followed", func(t *testing.T) {
		t.Parallel()
		// given
		root := twinTree(t, nil)

		// when
		found := findings(t, checkAdvisoryTwins, root)

		// then
		assert.Equal(t, []string{
			`azure-devops/global/stages/20-security/codeql.yaml: "global/scripts/tools/codeql/run.sh" is listed as ` +
				"advisory but is not -- remove the entry",
			`azure-devops/global/stages/20-security/gitleaks.yaml: "global/scripts/tools/gitleaks/run.sh" is listed ` +
				"as advisory but is not -- remove the entry",
			`azure-devops/global/stages/20-security/hadolint.yaml: "global/scripts/tools/hadolint/run.sh" is listed ` +
				"as advisory but is not -- remove the entry",
		}, found)
	})

	t.Run("should name an unlisted step by its runner when a template's step may fail", func(t *testing.T) {
		t.Parallel()
		// given
		root := twinTree(t, map[string]string{
			"azure-devops/golang/stages/20-security/go.yaml": "jobs:\n  - job: sca_govulncheck\n    steps:\n" +
				"      - bash: echo global/scripts/languages/golang/govulncheck/run.sh\n        continueOnError: 'yes'\n",
		})

		// when
		found := findings(t, checkAdvisoryTwins, root)

		// then
		assert.Contains(t, found, `azure-devops/golang/stages/20-security/go.yaml: step `+
			`"global/scripts/languages/golang/govulncheck/run.sh" of job sca_govulncheck is `+
			"`continueOnError` -- a failure passes the stage; remove it, or list it in AZURE_ADVISORY with its reason")
	})

	t.Run("should report a check it never read when a stage loses its job", func(t *testing.T) {
		t.Parallel()
		// given
		root := twinTree(t, map[string]string{
			"gitlab/golang/stages/20-security/go.yaml": "other:\n  script: [ run ]\n",
		})

		// when
		found := findings(t, checkAdvisoryTwins, root)

		// then
		assert.Contains(t, found, "gitlab: no job sca:govulncheck found in the Go stages or their templates -- "+
			"the scan cannot vouch for a check it never read")
	})
}

func TestTemplatePath(t *testing.T) {
	t.Parallel()

	cases := map[string]struct{ relative, template, want string }{
		"should resolve a template against the directory of the file naming it": {
			"azure-devops/golang/stages/20-security/go.yaml", "../../../global/stages/20-security/semgrep.yaml",
			"azure-devops/global/stages/20-security/semgrep.yaml",
		},
		"should keep an absolute template as it is written": {
			"azure-devops/golang/stages/20-security/go.yaml", "/templates/./x.yaml", "/templates/x.yaml",
		},
	}
	for name, values := range cases {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			// given
			relative, template := values.relative, values.template

			// when
			got := templatePath(relative, template)

			// then
			assert.Equal(t, values.want, got)
		})
	}
}
