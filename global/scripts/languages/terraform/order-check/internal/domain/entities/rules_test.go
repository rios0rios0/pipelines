package entities_test

import (
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/rios0rios0/pipelines/global/scripts/languages/terraform/order-check/internal/domain/entities"
)

const unorderedRoot = `dependency "kubernetes" {
  config_path = "${get_path_to_repo_root()}//environments/03_kubernetes/x"
}

dependency "shared" {
  config_path = "${get_path_to_repo_root()}//environments/01_shared/x"
}

terraform {
  source = "${get_path_to_repo_root()}//stacks/04_app"
}

inputs = {
  tags = local.tags
  kube = dependency.kubernetes.outputs.kube
  registry = dependency.shared.outputs.registry
  image = "app:1.0.0"
}
`

func TestCheckRootHcl(t *testing.T) {
	t.Parallel()

	t.Run("should report dependencies and inputs out of order with their numbers when checking", func(t *testing.T) {
		t.Parallel()
		// given
		root, err := entities.ParseRootHcl(unorderedRoot)
		require.NoError(t, err)

		// when
		findings, _, changed, err := entities.CheckRootHcl(root, unorderedRoot, "environments/04_app/root.hcl", false)

		// then
		require.NoError(t, err)
		assert.False(t, changed)
		require.Len(t, findings, 2)
		assert.Equal(t, "dependency blocks not ascending by environments/NN number: kubernetes(03), shared(01)",
			findings[0].Message)
		assert.Equal(t, "inputs not grouped by ascending dependency number: kubernetes(03), shared(01)",
			findings[1].Message)
		assert.Equal(t, "04_app", root.Stack)
	})

	t.Run("should sort both and keep locals first and literals last when fixing", func(t *testing.T) {
		t.Parallel()
		// given
		root, err := entities.ParseRootHcl(unorderedRoot)
		require.NoError(t, err)

		// when
		findings, rewritten, changed, err := entities.CheckRootHcl(root, unorderedRoot, "root.hcl", true)

		// then
		require.NoError(t, err)
		assert.Empty(t, findings)
		assert.True(t, changed)
		assert.Less(
			t,
			strings.Index(rewritten, `dependency "shared"`),
			strings.Index(rewritten, `dependency "kubernetes"`),
		)
		assert.Contains(t, rewritten, "  tags = local.tags\n  registry = dependency.shared.outputs.registry\n"+
			"  kube = dependency.kubernetes.outputs.kube\n  image = \"app:1.0.0\"\n")
	})
}

func TestCheckVariables(t *testing.T) {
	t.Parallel()

	inputs := map[string]entities.Number{"kube": entities.ParseNumber("03"), "registry": entities.ParseNumber("01")}

	t.Run("should only warn when a file has no section markers", func(t *testing.T) {
		t.Parallel()
		// given
		source := "variable \"kube\" {}\nvariable \"registry\" {}\n"

		// when
		findings, _, _, err := entities.CheckVariables(source, "variables.tf", inputs, false)

		// then
		require.NoError(t, err)
		require.Len(t, findings, 1)
		assert.Equal(t, entities.SeverityWarning, findings[0].Severity)
	})

	t.Run("should name the first regression and leave tags alone when checking", func(t *testing.T) {
		t.Parallel()
		// given
		source := "// SET ON .HCL\nvariable \"tags\" {}\nvariable \"kube\" {}\nvariable \"registry\" {}\n" +
			"// SET ON .ENV\nvariable \"environment\" {}\n"

		// when
		findings, _, _, err := entities.CheckVariables(source, "variables.tf", inputs, false)

		// then
		require.NoError(t, err)
		require.Len(t, findings, 1)
		assert.Equal(t, "`.HCL` variables not ordered by dependency number ('registry'(dep 01) after dep 03 ('kube'))",
			findings[0].Message)
	})

	t.Run("should sort the fed variables among their slots and pin the rest when fixing", func(t *testing.T) {
		t.Parallel()
		// given
		source := "# SET ON .HCL\nvariable \"kube\" {}\nvariable \"tags\" {}\nvariable \"registry\" {}\n"

		// when
		findings, rewritten, changed, err := entities.CheckVariables(source, "variables.tf", inputs, true)

		// then
		require.NoError(t, err)
		assert.Empty(t, findings)
		assert.True(t, changed)
		assert.Equal(
			t,
			"# SET ON .HCL\nvariable \"registry\" {}\nvariable \"tags\" {}\nvariable \"kube\" {}\n",
			rewritten,
		)
	})

	t.Run("should fail when the .ENV section comes first", func(t *testing.T) {
		t.Parallel()
		// given
		source := "// set on .env\nvariable \"environment\" {}\n// SET ON .HCL\n"

		// when
		findings, _, _, err := entities.CheckVariables(source, "variables.tf", inputs, false)

		// then
		require.NoError(t, err)
		require.Len(t, findings, 1)
		assert.Equal(t, "variables-sections", findings[0].Rule)
	})
}

func TestCheckProviders(t *testing.T) {
	t.Parallel()

	weights := entities.NewConfig(entities.DefaultProviderOrder()).Weights
	source := "terraform {\n  required_providers {\n    random = {\n      source = \"hashicorp/random\"\n    }\n" +
		"    mystery = {\n      source = \"acme/mystery\"\n    }\n    azurerm = {\n      source = \"hashicorp/azurerm\"\n" +
		"    }\n  }\n}\n\nprovider \"random\" {}\n\nprovider \"azurerm\" {\n  features {}\n}\n"

	t.Run("should warn about an unknown provider and list the misordered ones when checking", func(t *testing.T) {
		t.Parallel()
		// given
		path := "providers.tf"

		// when
		findings, _, _, err := entities.CheckProviders(source, path, weights, false)

		// then
		require.NoError(t, err)
		require.Len(t, findings, 3)
		assert.Equal(t, "providers not in the ranking (add to .terraform-order.json): mystery", findings[0].Message)
		assert.Equal(t, "required_providers not ordered heaviest->lightest: ['random', 'mystery', 'azurerm']",
			findings[1].Message)
		assert.Equal(t, "provider blocks not ordered heaviest->lightest: ['random', 'azurerm']", findings[2].Message)
	})

	t.Run("should sort the ranked ones around the unknown one when fixing", func(t *testing.T) {
		t.Parallel()
		// given
		path := "providers.tf"

		// when
		_, rewritten, changed, err := entities.CheckProviders(source, path, weights, true)

		// then
		require.NoError(t, err)
		assert.True(t, changed)
		assert.Less(t, strings.Index(rewritten, "azurerm = {"), strings.Index(rewritten, "mystery = {"))
		assert.Less(t, strings.Index(rewritten, "mystery = {"), strings.Index(rewritten, "random = {"))
		assert.Less(t, strings.Index(rewritten, `provider "azurerm"`), strings.Index(rewritten, `provider "random"`))
	})
}

func TestCheckOutputs(t *testing.T) {
	t.Parallel()

	positions := func() (map[string]int, error) { return map[string]int{"module.alpha": 0, "module.beta": 1}, nil }
	source := "output \"b\" {\n  value = module.beta.id\n}\n\noutput \"p\" {\n  value = var.x\n}\n\n" +
		"output \"a\" {\n  value = module.alpha.id\n}\n"

	t.Run("should report the first output placed before what it follows when checking", func(t *testing.T) {
		t.Parallel()
		// given
		path := "outputs.tf"

		// when
		findings, _, _, err := entities.CheckOutputs(source, path, positions, false)

		// then
		require.NoError(t, err)
		require.Len(t, findings, 1)
		assert.Equal(t, "outputs not ordered by main*.tf module/resource declaration order "+
			"('a'(pos 00) after pos 01 ('b'))", findings[0].Message)
	})

	t.Run("should keep a pass-through output with the output before it when fixing", func(t *testing.T) {
		t.Parallel()
		// given
		path := "outputs.tf"

		// when
		_, rewritten, changed, err := entities.CheckOutputs(source, path, positions, true)

		// then
		require.NoError(t, err)
		assert.True(t, changed)
		assert.Less(t, strings.Index(rewritten, `output "a"`), strings.Index(rewritten, `output "b"`))
		assert.Less(t, strings.Index(rewritten, `output "b"`), strings.Index(rewritten, `output "p"`))
	})
}

func TestDeadInputs(t *testing.T) {
	t.Parallel()

	t.Run("should name every top-level input no variable declares", func(t *testing.T) {
		t.Parallel()
		// given
		source := "inputs = {\n  known = \"x\"\n  nested = {\n    inner = 1\n  }\n  ghost = \"y\"\n}\n"
		declared := map[string]bool{"known": true, "nested": true}

		// when
		findings, err := entities.DeadInputs(source, "terragrunt.hcl", "stacks/app", declared)

		// then
		require.NoError(t, err)
		require.Len(t, findings, 1)
		assert.Equal(t, "input(s) not declared as a variable in stacks/app (dead code -- remove them, or declare the "+
			"variable): ghost", findings[0].Message)
	})
}

func TestLiteralStackPath(t *testing.T) {
	t.Parallel()

	t.Run("should read a literal stack path and refuse an interpolated one", func(t *testing.T) {
		t.Parallel()
		// given
		literal := `source = "${get_path_to_repo_root()}//stacks/01_shared/02_common/"`
		dynamic := `source = "${get_path_to_repo_root()}//stacks/${basename(get_terragrunt_dir())}"`

		// when
		path, found := entities.LiteralStackPath(literal)
		_, dynamicFound := entities.LiteralStackPath(dynamic)

		// then
		assert.True(t, found)
		assert.Equal(t, "01_shared/02_common", path)
		assert.False(t, dynamicFound)
	})
}
