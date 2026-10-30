package commands_test

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/rios0rios0/pipelines/global/scripts/languages/terraform/order-check/internal/domain/commands"
	"github.com/rios0rios0/pipelines/global/scripts/languages/terraform/order-check/internal/domain/entities"
	"github.com/rios0rios0/pipelines/global/scripts/languages/terraform/order-check/internal/test/doubles"
)

const rootHcl = `dependency "kubernetes" {
  config_path = "${get_path_to_repo_root()}//environments/03_kubernetes/x"
}

dependency "shared" {
  config_path = "${get_path_to_repo_root()}//environments/01_shared/x"
}

terraform {
  source = "${get_path_to_repo_root()}//stacks/04_app"
}

inputs = {
  kube     = dependency.kubernetes.outputs.kube
  registry = dependency.shared.outputs.registry
  orphan   = "nothing declares me"
}
`

const variablesTf = `// SET ON .HCL
variable "kube" {}
variable "registry" {}
`

func repository() *doubles.InMemoryWorkspace {
	return doubles.NewInMemoryWorkspace(map[string]string{
		"environments/04_app/root.hcl":                 rootHcl,
		"environments/04_app/prod/inst/terragrunt.hcl": "include \"root\" {}\ninputs = {\n  ghost = 1\n}\n",
		"stacks/04_app/variables.tf":                   variablesTf,
		"stacks/04_app/main.tf":                        "module \"a\" {}\n",
		"stacks/01_shared/02_common/variables.tf":      "variable \"x\" {}\n",
		".terraform/providers.tf":                      "terraform {\n  required_providers {\n    random = {}\n    azurerm = {}\n  }\n}\n",
	})
}

func defaultConfig() entities.Config {
	return entities.NewConfig(entities.DefaultProviderOrder())
}

func TestCheckOrderCommand(t *testing.T) {
	t.Parallel()

	t.Run("should report every rule a file breaks, in the order the files are checked", func(t *testing.T) {
		t.Parallel()
		// given
		workspace := repository()

		// when
		results, err := commands.NewCheckOrderCommand(workspace, defaultConfig()).Execute(false)

		// then
		require.NoError(t, err)
		require.Len(t, results, 3)
		assert.Equal(t, "environments/04_app/root.hcl", results[0].Path)
		assert.Equal(t, []string{"root-hcl-deps", "root-hcl-inputs", "dead-inputs"},
			[]string{results[0].Findings[0].Rule, results[0].Findings[1].Rule, results[0].Findings[2].Rule})
		assert.Contains(t, results[0].Findings[2].Message, "in stacks/04_app (dead code")
		assert.Equal(t, "stacks/04_app/variables.tf", results[1].Path)
		assert.Equal(t, "environments/04_app/prod/inst/terragrunt.hcl", results[2].Path)
		assert.Contains(t, results[2].Findings[0].Message, ": ghost")
		assert.Empty(t, workspace.Writes)
	})

	t.Run("should rewrite what it can when fixing and keep reporting dead inputs", func(t *testing.T) {
		t.Parallel()
		// given
		workspace := repository()

		// when
		results, err := commands.NewCheckOrderCommand(workspace, defaultConfig()).Execute(true)

		// then
		require.NoError(t, err)
		assert.Equal(
			t,
			[]string{"/repo/environments/04_app/root.hcl", "/repo/stacks/04_app/variables.tf"},
			workspace.Writes,
		)
		assert.True(t, results[0].Fixed)
		require.Len(t, results[0].Findings, 1)
		assert.Equal(t, "dead-inputs", results[0].Findings[0].Rule)
	})

	t.Run("should skip what the config ignores, and the mapping an ignored root.hcl gave", func(t *testing.T) {
		t.Parallel()
		// given
		// With the root ignored, nothing maps the stack's variables to
		// dependency numbers, so rule C has no order to hold them to.
		workspace := repository()
		config, err := entities.ParseConfig([]byte(`{"ignore": ["environments/*"]}`))
		require.NoError(t, err)

		// when
		results, err := commands.NewCheckOrderCommand(workspace, config).Execute(false)

		// then
		require.NoError(t, err)
		assert.Empty(t, results)
	})
}
