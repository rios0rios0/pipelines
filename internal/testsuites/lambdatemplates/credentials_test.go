package main

import (
	"bytes"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// The steps of a SAM delivery as the template writes them: the build alone, in a
// plain step, ahead of a packaging step for each way of holding the credentials.
const (
	samBuildStep = `    - script: |
        set -e
        sam build
      displayName: 'Build'
      condition: and(succeeded(), eq(variables['DEPLOY_STRATEGY'], 'sam'))
      env:
        AWS_REGION: $(AWS_REGION)
        AWS_DEFAULT_REGION: $(AWS_REGION)
`
	awsPackageStep = `    - task: 'AWSShellScript@1'
      displayName: 'Package (AWS)'
      condition: and(succeeded(), ne(variables['AWS_SERVICE_CONNECTION'], ''))
      inputs:
        regionName: "$(AWS_REGION)"
        inlineScript: |
          if [ -n "$SAM_S3_BUCKET" ]; then
            sam package --s3-bucket "$SAM_S3_BUCKET"
          fi
`
	plainPackageStep = `    - script: |
        sam package --resolve-s3
      displayName: 'Package'
      condition: and(succeeded(), eq(variables['AWS_SERVICE_CONNECTION'], ''))
`
	// The step the template used to run: one AWS task that builds, then packages.
	awsBuildAndPackageStep = `    - task: 'AWSShellScript@1'
      displayName: 'Build and Package (AWS)'
      condition: ne(variables['AWS_SERVICE_CONNECTION'], '')
      inputs:
        regionName: "$(AWS_REGION)"
        inlineScript: |
          sam build
          sam package --resolve-s3
`
)

// deliveryPath is where the repository keeps the delivery stage template.
const deliveryPath = "azure-devops/golang/stages/40-delivery/lambda.yaml"

// delivery is a delivery stage template whose one job runs the steps, in order.
func delivery(steps ...string) string {
	return "parameters: []\nstages:\n- stage: 'delivery'\n  jobs:\n  - job: 'delivery'\n    steps:\n" +
		strings.Join(steps, "")
}

func TestCheckCredentials(t *testing.T) {
	t.Parallel()

	t.Run("should pass when a plain step builds first and alone, in the packaging region", func(t *testing.T) {
		t.Parallel()
		// given
		root := repository(t, map[string]string{
			deliveryPath: delivery(samBuildStep, awsPackageStep, plainPackageStep),
		})

		// when
		var output bytes.Buffer
		err := checkCredentials(root, &output)

		// then
		require.NoError(t, err)
		assert.Equal(t, "  ✓ delivery/lambda.yaml\n", output.String())
	})

	cases := map[string]struct {
		steps    []string
		problems []string
	}{
		"should fail when an AWS task builds and packages in one step, as the template used to": {
			steps: []string{awsBuildAndPackageStep},
			problems: []string{
				"'Build and Package (AWS)' runs `sam build` in an AWSShellScript task, " +
					"holding the service connection's credentials while it builds",
				"'Build and Package (AWS)' runs `sam build` and `sam package` in one step",
				"'Build and Package (AWS)' has a condition without `succeeded()`, so it runs after a failed step",
			},
		},
		"should fail when a step packages before the build": {
			steps:    []string{plainPackageStep, samBuildStep},
			problems: []string{"'Package' runs `sam package` before 'Build' builds"},
		},
		"should fail when a packaging step would run after a failed build": {
			steps: []string{samBuildStep, strings.Replace(plainPackageStep,
				"and(succeeded(), eq(variables['AWS_SERVICE_CONNECTION'], ''))",
				"eq(variables['AWS_SERVICE_CONNECTION'], '')", 1)},
			problems: []string{"'Package' has a condition without `succeeded()`, so it runs after a failed step"},
		},
		"should fail when the build would run after a failed step": {
			steps: []string{strings.Replace(samBuildStep,
				"and(succeeded(), eq(variables['DEPLOY_STRATEGY'], 'sam'))",
				"eq(variables['DEPLOY_STRATEGY'], 'sam')", 1), plainPackageStep},
			problems: []string{"'Build' has a condition without `succeeded()`, so it runs after a failed step"},
		},
		"should fail when the build does not have the region the AWS task packages in": {
			steps: []string{
				strings.Replace(samBuildStep, "        AWS_DEFAULT_REGION: $(AWS_REGION)\n", "", 1),
				awsPackageStep,
			},
			problems: []string{
				"'Build' does not set AWS_DEFAULT_REGION to $(AWS_REGION), the region 'Package (AWS)' packages in",
			},
		},
		"should fail when two steps build": {
			steps:    []string{samBuildStep, samBuildStep, plainPackageStep},
			problems: []string{"'Build' runs `sam build` a second time"},
		},
		"should fail when a step packages and none builds": {
			steps:    []string{plainPackageStep},
			problems: []string{"no step runs `sam build`"},
		},
		"should fail when the build is packaged by no step": {
			steps:    []string{samBuildStep},
			problems: []string{"no step runs `sam package`"},
		},
		"should fail when no step runs SAM at all": {
			steps:    []string{"    - script: 'go build ./...'\n"},
			problems: []string{"no step runs `sam build`"},
		},
	}
	for name, scenario := range cases {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			// given
			root := repository(t, map[string]string{deliveryPath: delivery(scenario.steps...)})

			// when
			var output bytes.Buffer
			err := checkCredentials(root, &output)

			// then
			require.ErrorIs(t, err, errFailed)
			var expected strings.Builder
			expected.WriteString("\nErrors found:\n")
			for _, problem := range scenario.problems {
				expected.WriteString("  ✗ delivery/lambda.yaml: " + problem + "\n")
			}
			assert.Equal(t, expected.String(), output.String())
		})
	}

	t.Run("should fail and name the parser's error when the delivery template does not parse", func(t *testing.T) {
		t.Parallel()
		// given
		root := repository(t, map[string]string{deliveryPath: "stages: [\n"})

		// when
		err := checkCredentials(root, &bytes.Buffer{})

		// then
		require.ErrorContains(t, err, deliveryPath+": yaml: line")
	})
}
