// Command order-check checks, and with `--fix` rewrites, a Terragrunt
// monorepo against the team's file-ordering standard, and reports dead
// terragrunt inputs. See internal/cli for the rules and the command line.
package main

import (
	"os"

	"github.com/rios0rios0/pipelines/global/scripts/languages/terraform/order-check/internal/cli"
)

func main() {
	os.Exit(cli.Run(os.Args[1:], os.Stdout, os.Stderr))
}
