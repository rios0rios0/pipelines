// Command cyclonedx-licenses makes every license id in a CycloneDX JSON BOM one the SPDX license
// list Dependency-Track validates against holds, so the server accepts the BOM. The Go CycloneDX
// generator (`../run.sh`) runs it on the BOM cyclonedx-gomod wrote; see internal/cli for the
// command line.
package main

import (
	"os"

	"github.com/rios0rios0/pipelines/global/scripts/languages/golang/cyclonedx/licenses/internal/cli"
)

func main() {
	os.Exit(cli.Run(os.Args[1:], os.Stdout, os.Stderr))
}
