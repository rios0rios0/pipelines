// Command tftest-gen generates `tests/smoke.tftest.hcl` for a single-module
// Terraform repository: mocked providers, a plan-time smoke run, and one run
// per validated required variable. See internal/cli for the command line.
package main

import (
	"os"

	"github.com/rios0rios0/pipelines/global/scripts/languages/terraform/tftest-gen/internal/cli"
)

func main() {
	os.Exit(cli.Run(os.Args[1:], os.Stdout, os.Stderr))
}
