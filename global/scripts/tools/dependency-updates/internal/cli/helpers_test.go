package cli_test

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/stretchr/testify/require"

	"github.com/rios0rios0/pipelines/global/scripts/tools/dependency-updates/internal/cli"
)

// outcome is one run of the command line.
type outcome struct {
	exit   int
	stdout string
	stderr string
}

func (o outcome) output() string {
	return o.stdout + o.stderr
}

// run runs the command line in `workdir`.
func run(t *testing.T, workdir string, arguments ...string) outcome {
	t.Helper()
	var stdout, stderr bytes.Buffer
	exit := cli.RunIn(workdir, arguments, &stdout, &stderr)
	return outcome{exit: exit, stdout: stdout.String(), stderr: stderr.String()}
}

// writeFiles lays `files` out under `root`.
func writeFiles(t *testing.T, root string, files map[string]string) {
	t.Helper()
	for name, content := range files {
		path := filepath.Join(root, filepath.FromSlash(name))
		require.NoError(t, os.MkdirAll(filepath.Dir(path), 0o750))
		require.NoError(t, os.WriteFile(path, []byte(content), 0o600))
	}
}

// writeJSON writes a fixture document.
func writeJSON(t *testing.T, path string, value any) {
	t.Helper()
	content, err := json.MarshalIndent(value, "", " ")
	require.NoError(t, err)
	require.NoError(t, os.WriteFile(path, content, 0o600))
}

func read(t *testing.T, path string) string {
	t.Helper()
	content, err := os.ReadFile(path)
	require.NoError(t, err)
	return string(content)
}

// repeat is `count` copies of one character: a digest-shaped value with no
// entropy, so no secret scanner mistakes a fixture for a credential.
func repeat(character string, count int) string {
	return strings.Repeat(character, count)
}

// repositoryRoot is this repository, from the package's directory.
func repositoryRoot(t *testing.T) string {
	t.Helper()
	root, err := filepath.Abs(filepath.Join("..", "..", "..", "..", "..", ".."))
	require.NoError(t, err)
	require.FileExists(t, filepath.Join(root, "global", "scripts", "shared", "pinned-versions.sh"))
	return root
}

// sampleRepository is a miniature repository with one pin of every shape the
// check understands.
func sampleRepository(t *testing.T, root string) {
	t.Helper()
	writeFiles(t, root, map[string]string{
		"global/scripts/shared/pinned-versions.sh": "#!/usr/bin/env sh\n" +
			"# upstream: github-release example/binary\n# osv: none\n" +
			"BINARY_PINNED_VERSION=\"1.2.3\"\nBINARY_VERSION=\"${BINARY_VERSION:-${BINARY_PINNED_VERSION}}\"\n\n" +
			"# upstream: pypi examplepkg\nEXAMPLEPKG_SPEC=\"${EXAMPLEPKG_SPEC:-examplepkg==2.0.0}\"\n\n" +
			"# upstream: npm examplecli\nEXAMPLECLI_SPEC=\"${EXAMPLECLI_SPEC:-examplecli@4}\"\n\n" +
			"# upstream: github-release example/held track=1\n# osv: none\n" +
			"HELD_PINNED_VERSION=\"1.5.0\"\nHELD_VERSION=\"${HELD_VERSION:-${HELD_PINNED_VERSION}}\"\n",
		".github/workflows/sample.yaml": "jobs:\n  build:\n    steps:\n" +
			"      - uses: 'someorg/someaction@" + repeat("1", 40) + "' # v3.1.0\n" +
			"      - uses: 'rios0rios0/pipelines/github/global/abstracts/scripts-repo@main'\n" +
			"    container:\n      image: 'someimage:1.0@sha256:" + repeat("a", 64) + "'\n",
		"containers/Dockerfile": "FROM otherimage:2.0@sha256:" + repeat("b", 64) + "\n",
	})
}

// currentAnswers are upstream answers under which every sample pin is current.
func currentAnswers() map[string]any {
	return map[string]any{
		"osv:*":                                          []any{},
		"github-release:example/binary":                  "v1.2.3",
		"pypi:examplepkg":                                "2.0.0",
		"npm:examplecli":                                 "4.99.1",
		"github-release:example/held":                    "v1.5.0",
		"github-release:someorg/someaction":              "v3.1.0",
		"image:someimage:1.0@sha256:" + repeat("a", 64):  "sha256:" + repeat("a", 64),
		"image:otherimage:2.0@sha256:" + repeat("b", 64): "sha256:" + repeat("b", 64),
	}
}

// staleAnswers move every sample pin.
func staleAnswers() map[string]any {
	answers := currentAnswers()
	answers["github-release:example/binary"] = "v1.3.0"
	answers["pypi:examplepkg"] = "2.1.0"
	answers["npm:examplecli"] = "5.0.0"
	answers["github-release:example/held"] = "v2.0.0"
	answers["github-release:someorg/someaction"] = "v4.0.0"
	answers["image:someimage:1.0@sha256:"+repeat("a", 64)] = "sha256:" + repeat("c", 64)
	answers["image:otherimage:2.0@sha256:"+repeat("b", 64)] = "sha256:" + repeat("c", 64)
	return answers
}
