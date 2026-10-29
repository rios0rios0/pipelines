// Command dartpipeline is the document reader .github/tests/test-dart-pipeline.sh
// builds and runs: it prints a YAML template as JSON for the suite's jq
// assertions, and checks that a generated report is well-formed XML. Test
// support only -- nothing a consumer runs depends on it. See documents for the
// command line.
package main

import (
	"os"

	"github.com/rios0rios0/pipelines/internal/testsuites/dartpipeline/documents"
)

func main() {
	os.Exit(documents.Run(os.Args[1:], os.Stdout, os.Stderr))
}
