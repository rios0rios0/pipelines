package main

import (
	"bytes"
	"maps"
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

const mainTemplate = `parameters:
  - name: 'LAMBDA_FUNCTION_NAME'
    type: string
stages:
  - template: 'stages/40-delivery/lambda.yaml'
    parameters:
      NAME: ${{ parameters.LAMBDA_FUNCTION_NAME }}
`

// repository lays out the four Lambda templates, then `files` over them.
func repository(t *testing.T, files map[string]string) string {
	t.Helper()
	root := t.TempDir()
	all := map[string]string{
		"azure-devops/golang/go-lambda.yaml":                   mainTemplate,
		"azure-devops/golang/go-lambda-sam.yaml":               mainTemplate,
		"azure-devops/golang/stages/40-delivery/lambda.yaml":   "parameters: []\nstages: []\n",
		"azure-devops/golang/stages/50-deployment/lambda.yaml": "stages: []\n",
	}
	maps.Copy(all, files)
	for name, content := range all {
		path := filepath.Join(root, filepath.FromSlash(name))
		require.NoError(t, os.MkdirAll(filepath.Dir(path), 0o750))
		require.NoError(t, os.WriteFile(path, []byte(content), 0o600))
	}
	return root
}

func TestCheckSyntax(t *testing.T) {
	t.Parallel()

	t.Run("should list every template as parsing when they all do", func(t *testing.T) {
		t.Parallel()
		// given
		root := repository(t, nil)

		// when
		var output bytes.Buffer
		err := checkSyntax(root, &output)

		// then
		require.NoError(t, err)
		assert.Equal(t, "  ✓ azure-devops/golang/go-lambda.yaml\n  ✓ azure-devops/golang/go-lambda-sam.yaml\n"+
			"  ✓ azure-devops/golang/stages/40-delivery/lambda.yaml\n"+
			"  ✓ azure-devops/golang/stages/50-deployment/lambda.yaml\n", output.String())
	})

	t.Run("should fail and name the parser's error when a template does not parse", func(t *testing.T) {
		t.Parallel()
		// given
		root := repository(t, map[string]string{"azure-devops/golang/go-lambda.yaml": "stages: [\n"})

		// when
		var output bytes.Buffer
		err := checkSyntax(root, &output)

		// then
		require.ErrorIs(t, err, errFailed)
		assert.Contains(t, output.String(), "  ✗ azure-devops/golang/go-lambda.yaml: yaml: line")
	})
}

func TestCheckStructure(t *testing.T) {
	t.Parallel()

	t.Run("should list every template when each carries its keys", func(t *testing.T) {
		t.Parallel()
		// given
		root := repository(t, nil)

		// when
		var output bytes.Buffer
		err := checkStructure(root, &output)

		// then
		require.NoError(t, err)
		assert.Equal(t, "  ✓ go-lambda.yaml\n  ✓ go-lambda-sam.yaml\n  ✓ delivery/lambda.yaml\n"+
			"  ✓ deployment/lambda.yaml\n", output.String())
	})

	t.Run("should list every problem when templates miss their keys or name a stage oddly", func(t *testing.T) {
		t.Parallel()
		// given
		root := repository(t, map[string]string{
			"azure-devops/golang/go-lambda.yaml":                   "stages:\n  - template: 'stages/a.yml'\n  - x\n",
			"azure-devops/golang/stages/50-deployment/lambda.yaml": "jobs: []\n",
		})

		// when
		var output bytes.Buffer
		err := checkStructure(root, &output)

		// then
		require.ErrorIs(t, err, errFailed)
		assert.Equal(t, "  ✓ go-lambda-sam.yaml\n  ✓ delivery/lambda.yaml\n\nErrors found:\n"+
			"  ✗ go-lambda.yaml: Missing 'parameters' key (expected for main templates)\n"+
			"  ✗ go-lambda.yaml: Stage 1 template doesn't end with .yaml\n"+
			"  ✗ deployment/lambda.yaml: Missing both 'stages' and 'parameters' keys\n", output.String())
	})
}

func TestCheckParameters(t *testing.T) {
	t.Parallel()

	t.Run("should list every main template when it defines exactly what it references", func(t *testing.T) {
		t.Parallel()
		// given
		root := repository(t, nil)

		// when
		var output bytes.Buffer
		err := checkParameters(root, &output)

		// then
		require.NoError(t, err)
		assert.Equal(t, "  ✓ go-lambda.yaml\n  ✓ go-lambda-sam.yaml\n", output.String())
	})

	t.Run("should warn about an unused parameter and fail on an undefined one, both sorted", func(t *testing.T) {
		t.Parallel()
		// given
		root := repository(t, map[string]string{
			"azure-devops/golang/go-lambda.yaml": "parameters:\n  - name: 'LAMBDA_FUNCTION_NAME'\n  - name: 'SPARE'\n" +
				"  - name: 'EXTRA'\nstages:\n  - template: x.yaml\n    parameters: {N: '${{ parameters.LAMBDA_FUNCTION_NAME }}'}\n",
			"azure-devops/golang/go-lambda-sam.yaml": mainTemplate +
				"variables:\n  x: '${{parameters.ZETA}} ${{ parameters.ALPHA }}'\n",
		})

		// when
		var output bytes.Buffer
		err := checkParameters(root, &output)

		// then
		require.ErrorIs(t, err, errFailed)
		assert.Equal(t, "\nWarnings:\n"+
			"  ⚠ go-lambda.yaml: Parameter 'EXTRA' defined but not used\n"+
			"  ⚠ go-lambda.yaml: Parameter 'SPARE' defined but not used\n"+
			"\nErrors:\n"+
			"  ✗ go-lambda-sam.yaml: Parameter 'ALPHA' referenced but not defined\n"+
			"  ✗ go-lambda-sam.yaml: Parameter 'ZETA' referenced but not defined\n", output.String())
	})

	t.Run("should fail when a parameter has no name", func(t *testing.T) {
		t.Parallel()
		// given
		root := repository(t, map[string]string{"azure-devops/golang/go-lambda.yaml": "parameters:\n  - type: x\n"})

		// when
		err := checkParameters(root, &bytes.Buffer{})

		// then
		require.ErrorContains(t, err, "parameter 1 has no name")
	})
}

func TestFileChecks(t *testing.T) {
	t.Parallel()

	cases := map[string]struct {
		check   func(string) error
		content string
		valid   bool
	}{
		"should accept a SAM template when it carries CloudFormation tags and its keys": {
			check: checkSAM, valid: true,
			content: "AWSTemplateFormatVersion: '2010-09-09'\nTransform: AWS::Serverless-2016-10-31\n" +
				"Resources: {}\nOutputs:\n  Url: {Value: !Sub 'https://${Api}'}\n  Arn: !GetAtt [Function, Arn]\n",
		},
		"should refuse a SAM template when it has no Transform": {
			check: checkSAM, content: "AWSTemplateFormatVersion: x\nResources: {}\n", valid: false,
		},
		"should refuse a SAM template when it does not parse": {
			check: checkSAM, content: "Resources: [\n", valid: false,
		},
		"should accept YAML when a pipeline parses": {
			check:   checkYAML,
			content: "steps: []\n",
			valid:   true,
		},
		"should refuse YAML when a pipeline does not parse": {
			check:   checkYAML,
			content: "steps: [\n",
			valid:   false,
		},
		"should refuse YAML when it carries a custom tag": {
			check:   checkYAML,
			content: "a: !Ref b\n",
			valid:   false,
		},
		"should accept JSON when the file is one document": {
			check:   checkJSON,
			content: "{\"a\": [1]}\n",
			valid:   true,
		},
		"should refuse JSON when the file has a trailing comma": {
			check:   checkJSON,
			content: "{\"a\": 1,}",
			valid:   false,
		},
		"should refuse JSON when the file holds two documents": {check: checkJSON, content: "{}{}", valid: false},
		"should refuse JSON when the file is not UTF-8":        {check: checkJSON, content: "\"\xff\"", valid: false},
	}
	for name, scenario := range cases {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			// given
			path := filepath.Join(t.TempDir(), "file")
			require.NoError(t, os.WriteFile(path, []byte(scenario.content), 0o600))

			// when
			err := scenario.check(path)

			// then
			if scenario.valid {
				require.NoError(t, err)
			} else {
				require.ErrorIs(t, err, errFailed)
			}
		})
	}
}

func TestRun(t *testing.T) {
	t.Parallel()

	t.Run("should print the usage and exit 2 when the command is unknown", func(t *testing.T) {
		t.Parallel()
		// given
		var stdout, stderr bytes.Buffer

		// when
		status := run([]string{"other", "x"}, &stdout, &stderr)

		// then
		assert.Equal(t, exitUsage, status)
		assert.Contains(t, stderr.String(), "usage:")
	})

	t.Run("should exit 1 quietly when a file check fails", func(t *testing.T) {
		t.Parallel()
		// given
		var stdout, stderr bytes.Buffer
		missing := filepath.Join(t.TempDir(), "missing.json")

		// when
		status := run([]string{"json", missing}, &stdout, &stderr)

		// then
		assert.Equal(t, exitFailed, status)
		assert.Empty(t, stdout.String())
		assert.Empty(t, stderr.String())
	})
}
