package main

import "regexp"

// A credential is recognised by its NAME. Suffix matching rather than a
// substring: `SONAR_PROJECT_KEY`, `S3_KEY_PREFIX` and `*_REPORT_PATH` are
// configuration, not credentials, and a substring match on "KEY" drowns the
// real findings in them.
var credentialName = regexp.MustCompile(`^[A-Z][A-Z0-9_]*(?:TOKEN|API_KEY|SECRET|PASSWORD|PASSWD|CREDENTIALS?)$`)

// stepKey names one step: the template it is in and its displayName.
type stepKey struct {
	file        string
	displayName string
}

// declaration is a step that must map credentials no script here names.
type declaration struct {
	step  stepKey
	names []string
}

// contract is how each credential-shaped variable is classified.
type contract struct {
	// extra are credentials whose names the suffix rule cannot reach.
	extra map[string]bool
	// declared are the steps a third-party tool reads a credential in.
	declared []declaration
	// exemptSteps never take the code path that reads the credential they name.
	exemptSteps map[stepKey][]string
	// exempt are classified and deliberately NOT asserted, each with its reason.
	exempt map[string]string
}

// isCredential reports whether a variable name is credential-shaped.
func (c contract) isCredential(name string) bool {
	return credentialName.MatchString(name) || c.extra[name]
}

// declaredNames are every credential the declared table names.
func (c contract) declaredNames() map[string]bool {
	names := map[string]bool{}
	for _, entry := range c.declared {
		for _, name := range entry.names {
			names[name] = true
		}
	}
	return names
}

// declaredFor are the credentials a step is declared to consume.
func (c contract) declaredFor(key stepKey) []string {
	for _, entry := range c.declared {
		if entry.step == key {
			return entry.names
		}
	}
	return nil
}

// secretContract is the classification this repository holds itself to.
func secretContract() contract {
	return contract{
		// `AWS_SECRET_ACCESS_KEY` carries "SECRET" in the middle and ends in the
		// same `_KEY` that `SONAR_PROJECT_KEY` does, so no suffix rule separates
		// them; they are named instead of loosening the rule and drowning the
		// findings in configuration.
		extra: map[string]bool{
			"AWS_ACCESS_KEY_ID":     true,
			"AWS_SECRET_ACCESS_KEY": true,
			"AWS_SESSION_TOKEN":     true,
			"GPG_PRIVATE_KEY":       true,
			"SSH_PRIVATE_KEY":       true,
		},
		// Credentials consumed by a tool that reads the environment directly, so
		// no script in this repository ever names them. Each entry names the step
		// that must map it.
		declared: []declaration{
			{
				step:  stepKey{"azure-devops/python/stages/20-security/pdm.yaml", "Run Safety dependency check"},
				names: []string{"SAFETY_API_KEY"},
			},
		},
		// Steps that run a script which NAMES a credential on a code path they
		// never take. The derived check reads a script as one body and cannot see
		// which branch a job's variables select, so the exemption carries the
		// reason.
		exemptSteps: map[stepKey][]string{
			// `publish:validate` sets DART_PUBLISH_DRY_RUN, and publish/run.sh exits
			// at that check -- above everything that touches PUB_TOKEN. Mapping the
			// token into a job that must never publish would hand a release
			// credential to the one job that runs on every main build.
			{"azure-devops/dart/stages/40-delivery/dart-library.yaml", "Validate the package (dry run)"}: {"PUB_TOKEN"},
		},
		// Classified and deliberately NOT asserted. Each needs a reason, so an
		// exemption is a decision on the record rather than an omission.
		//nolint:gosec // G101 reads the variable NAMES below as credentials; each value is the reason it is exempt
		exempt: map[string]string{
			// Generated per run by global/scripts/languages/golang/test/database.sh
			// (openssl rand). Never a pipeline variable, so nothing can withhold it.
			"POSTGRES_PASSWORD": "generated per run inside the script, not a pipeline variable",
			// Supplied by the Azure DevOps AWS service connection through
			// `AWSShellScript@1`, which injects them itself. The keys-in-variables
			// fallback is a separate, deliberate design decision: its steps GUARD on
			// the variables being absent and fail with an actionable message, and
			// mapping them through `env:` would defeat that guard, because an
			// undefined `$(AWS_ACCESS_KEY_ID)` arrives non-empty. Changing it is a
			// deployment-path change with its own test surface -- tracked separately.
			"AWS_ACCESS_KEY_ID":     awsServiceConnection,
			"AWS_SECRET_ACCESS_KEY": awsServiceConnection,
			"AWS_SESSION_TOKEN":     awsServiceConnection,
			// Azure's own predefined secret, mapped from $(System.AccessToken) rather
			// than from a variable group of the same name.
			"SYSTEM_ACCESSTOKEN": "mapped from the predefined $(System.AccessToken)",
			// GitLab predefined variables. GitLab injects every CI/CD variable into
			// the job environment, including masked ones, so the defect class does
			// not exist there.
			"CI_JOB_TOKEN":         gitLabPredefined,
			"CI_REGISTRY_PASSWORD": gitLabPredefined,
			// Consumed only by GitHub Actions workflows, where a secret is never
			// ambient and must always be passed explicitly -- a different contract,
			// enforced by the workflows themselves.
			"CLAUDE_CODE_OAUTH_TOKEN": "GitHub Actions only; secrets are never ambient there",
			"GH_TOKEN":                "GitHub Actions only; no Azure consumer",
			"GITHUB_TOKEN":            "GitHub Actions only; no Azure consumer",
			"SSH_PRIVATE_KEY":         "documentation example in a GitLab comment, not a consumed variable",
			"GPG_PRIVATE_KEY":         "GitHub Actions release signing only; no Azure consumer",
			// Passed to Gradle as a `-P` property through a task input. Task inputs
			// resolve secret variables, so the ambient-environment defect does not
			// apply to this path.
			"JAVA_PASSWORD": "reaches Gradle through a task input, which resolves secrets",
		},
	}
}

// The reasons several exempt credentials share.
const (
	awsServiceConnection = "service connection injects it; the variables fallback guards on absence"
	gitLabPredefined     = "GitLab predefined; GitLab injects masked variables too"
)
