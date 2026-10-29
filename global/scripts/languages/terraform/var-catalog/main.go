// Command var-catalog generates, from a Terragrunt repository's catalog of
// canonical `variable` bodies, the declarations each stack under `stacks/`
// uses, and with `--check` verifies the committed ones are up to date. See
// internal/cli for the command line.
package main

import (
	"os"

	"github.com/rios0rios0/pipelines/global/scripts/languages/terraform/var-catalog/internal/cli"
)

func main() {
	os.Exit(cli.Run(os.Args[1:], os.Stdout, os.Stderr))
}
