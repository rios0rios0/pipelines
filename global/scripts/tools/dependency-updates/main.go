// Command dependency-updates keeps every pinned third-party dependency current
// without ever proposing one known to be vulnerable or malicious: it reports
// what is stale or vulnerable, applies the safe updates for a pull request,
// verifies a pull request that moves pins, and guards the update branch.
// See internal/cli for the command line.
package main

import (
	"os"

	"github.com/rios0rios0/pipelines/global/scripts/tools/dependency-updates/internal/cli"
)

func main() {
	os.Exit(cli.Run(os.Args[1:], os.Stdout, os.Stderr))
}
