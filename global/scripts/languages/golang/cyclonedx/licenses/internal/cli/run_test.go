package cli_test

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/rios0rios0/pipelines/global/scripts/languages/golang/cyclonedx/licenses/internal/cli"
)

const (
	rejectedBOM = `{
  "bomFormat": "CycloneDX",
  "specVersion": "1.6",
  "components": [
    {
      "name": "github.com/golang/freetype",
      "evidence": {
        "licenses": [
          {
            "license": {
              "id": "deprecated_GPL-2.0+"
            }
          },
          {
            "license": {
              "id": "LicenseRef-acme"
            }
          }
        ]
      }
    }
  ]
}
`
	acceptedBOM = `{
  "bomFormat": "CycloneDX",
  "specVersion": "1.6",
  "components": [
    {
      "name": "github.com/golang/freetype",
      "evidence": {
        "licenses": [
          {
            "license": {
              "id": "GPL-2.0+"
            }
          },
          {
            "license": {
              "name": "LicenseRef-acme"
            }
          }
        ]
      }
    }
  ]
}
`
)

// writeBOM writes `content` as a BOM in a directory of its own and returns its path.
func writeBOM(t *testing.T, content string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "bom.json")
	require.NoError(t, os.WriteFile(path, []byte(content), 0o600))
	return path
}

// assertFile fails unless the file at `path` holds `want` byte for byte: a BOM with nothing to
// rewrite, or one that could not be read, must reach the uploader exactly as the generator wrote it.
func assertFile(t *testing.T, want, path string) {
	t.Helper()
	got, err := os.ReadFile(path)
	require.NoError(t, err)
	assert.Equal(t, strings.SplitAfter(want, "\n"), strings.SplitAfter(string(got), "\n"))
}

func run(arguments ...string) (int, string, string) {
	var stdout, stderr bytes.Buffer
	code := cli.Run(arguments, &stdout, &stderr)
	return code, stdout.String(), stderr.String()
}

func TestRun(t *testing.T) {
	t.Parallel()

	t.Run("should rewrite the BOM and name each rewrite when an id is not listed", func(t *testing.T) {
		t.Parallel()
		// given
		path := writeBOM(t, rejectedBOM)

		// when
		code, stdout, stderr := run(path)

		// then
		assert.Zero(t, code)
		assert.Empty(t, stderr)
		assertFile(t, acceptedBOM, path)
		assert.Contains(t, stdout, `cyclonedx-licenses: $.components[0].evidence.licenses[0].license: `+
			`"deprecated_GPL-2.0+" is the SPDX id "GPL-2.0+" under the name of its license-list file; wrote "GPL-2.0+"`)
		assert.Contains(t, stdout, `cyclonedx-licenses: $.components[0].evidence.licenses[1].license: `+
			`"LicenseRef-acme" is not an id of SPDX license list v1.0-3.27.0; wrote it as the license name`)
		assert.Contains(t, stdout, "cyclonedx-licenses: "+path+
			": 2 license id(s) checked against SPDX license list v1.0-3.27.0, 2 rewritten")
	})

	t.Run("should leave the BOM untouched when the list holds every id", func(t *testing.T) {
		t.Parallel()
		// given
		path := writeBOM(t, acceptedBOM)

		// when
		code, stdout, _ := run(path)

		// then
		assert.Zero(t, code)
		assertFile(t, acceptedBOM, path)
		assert.Equal(t, "cyclonedx-licenses: "+path+
			": 1 license id(s) checked against SPDX license list v1.0-3.27.0, 0 rewritten\n", stdout)
	})

	t.Run("should exit 1 and leave the file as it was when the BOM is not JSON", func(t *testing.T) {
		t.Parallel()
		// given
		path := writeBOM(t, `{"components": [`)

		// when
		code, stdout, stderr := run(path)

		// then
		assert.Equal(t, 1, code)
		assert.Empty(t, stdout)
		assert.Contains(t, stderr, "cyclonedx-licenses: "+path+": the BOM is not a JSON document")
		assertFile(t, `{"components": [`, path)
	})

	t.Run("should exit 1 when the BOM does not exist", func(t *testing.T) {
		t.Parallel()
		// given
		path := filepath.Join(t.TempDir(), "bom.json")

		// when
		code, _, stderr := run(path)

		// then
		assert.Equal(t, 1, code)
		assert.Contains(t, stderr, "could not read the BOM")
	})

	t.Run("should exit 2 and print the usage when the command line cannot be run", func(t *testing.T) {
		t.Parallel()
		for _, arguments := range [][]string{{}, {"a.json", "b.json"}, {"--bom"}, {""}} {
			// given
			given := arguments

			// when
			code, stdout, stderr := run(given...)

			// then
			assert.Equal(t, 2, code, "arguments %q", given)
			assert.Empty(t, stdout, "arguments %q", given)
			assert.Contains(t, stderr, "usage: cyclonedx-licenses <bom.json>", "arguments %q", given)
		}
	})

	t.Run("should print the usage and exit 0 when asked for help", func(t *testing.T) {
		t.Parallel()
		// given
		arguments := []string{"--help"}

		// when
		code, stdout, stderr := run(arguments...)

		// then
		assert.Zero(t, code)
		assert.Contains(t, stdout, "usage: cyclonedx-licenses <bom.json>")
		assert.Empty(t, stderr)
	})
}
