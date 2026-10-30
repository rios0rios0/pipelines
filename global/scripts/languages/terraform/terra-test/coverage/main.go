// Command terra-coverage writes a SonarQube generic coverage report for a
// Terraform module tree: which declared blocks an assertion `terraform test`
// runs actually reaches. The terra-test tier runs it after its tests; see
// internal/cli for the command line.
package main

import (
	"os"

	"github.com/rios0rios0/pipelines/global/scripts/languages/terraform/terra-test/coverage/internal/cli"
)

func main() {
	os.Exit(cli.Run(os.Args[1:], os.Stdout, os.Stderr))
}
