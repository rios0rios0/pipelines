// Command test-pyramid judges whether a pull request worsens its repository's test pyramid. See
// internal/cli for the command line and internal/domain/entities for the rules.
package main

import (
	"os"

	"github.com/rios0rios0/pipelines/global/scripts/tools/test-pyramid/internal/cli"
)

func main() {
	os.Exit(cli.Run(os.Args[1:], os.Getenv, os.Stdout, os.Stderr))
}
