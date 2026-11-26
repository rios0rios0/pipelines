// Package cli is the license normalisation's command line: it reads the BOM the Go CycloneDX
// generator wrote, makes every license id in it one the SPDX license list holds, and says what it
// rewrote in a line a CI log reads.
//
// Usage: cyclonedx-licenses <bom.json>
//
// Dependency-Track validates a BOM against the CycloneDX schema before it accepts it, and the
// schema enumerates the SPDX license ids a `license.id` may hold. cyclonedx-gomod writes the
// license its detector matched there verbatim, and the detector names a DEPRECATED SPDX license
// after its license-list file: `deprecated_GPL-2.0+`, which no list holds. One such component made
// the server refuse the whole BOM with HTTP 400, so the project kept no inventory at all.
//
// Exit status: 0 when every license id the BOM holds is one the list holds, after the rewrites; 1
// when the BOM could not be read, parsed or written, and then it is left as it was; 2 on a command
// line that cannot be run.
package cli

import (
	"fmt"
	"io"
	"strings"

	"github.com/rios0rios0/pipelines/global/scripts/languages/golang/cyclonedx/licenses/internal/domain/commands"
	"github.com/rios0rios0/pipelines/global/scripts/languages/golang/cyclonedx/licenses/internal/domain/entities"
	"github.com/rios0rios0/pipelines/global/scripts/languages/golang/cyclonedx/licenses/internal/infrastructure/repositories"
)

const (
	exitFailed = 1
	exitUsage  = 2
	prefix     = "cyclonedx-licenses: "
	usage      = "usage: cyclonedx-licenses <bom.json>\n\n" +
		"Makes every license id of a CycloneDX JSON BOM one the SPDX license list Dependency-Track\n" +
		"validates against holds: `deprecated_<id>` becomes `<id>`, and any other id the list does not\n" +
		"hold becomes the license's name. The BOM is rewritten in place, and only when an id changes."
)

// Run is the whole command: it reads `arguments`, writes to `stdout` and `stderr`, and returns the
// exit status.
func Run(arguments []string, stdout, stderr io.Writer) int {
	if len(arguments) == 1 && (arguments[0] == "-h" || arguments[0] == "--help") {
		_, _ = fmt.Fprintln(stdout, usage)
		return 0
	}
	if len(arguments) != 1 || arguments[0] == "" || strings.HasPrefix(arguments[0], "-") {
		_, _ = fmt.Fprintln(stderr, usage)
		return exitUsage
	}
	path := arguments[0]
	command := commands.NewNormalizeLicensesCommand(
		repositories.NewFileBOMRepository(path), repositories.NewEmbeddedLicenseListRepository(),
	)
	result, err := command.Execute()
	if err != nil {
		_, _ = fmt.Fprintf(stderr, "%s%s: %s\n", prefix, path, err)
		return exitFailed
	}
	for _, fix := range result.Fixes {
		_, _ = fmt.Fprintln(stdout, prefix+describe(fix, result.List))
	}
	_, _ = fmt.Fprintf(stdout, "%s%s: %d license id(s) checked against SPDX license list %s, %d rewritten\n",
		prefix, path, result.Checked, result.List, len(result.Fixes))
	return 0
}

func describe(fix entities.Fix, list string) string {
	if fix.Resolution.Verdict == entities.VerdictRestored {
		return fmt.Sprintf("%s: %q is the SPDX id %q under the name of its license-list file; wrote %q",
			fix.Path, fix.Written, fix.Resolution.ID, fix.Resolution.ID)
	}
	return fmt.Sprintf("%s: %q is not an id of SPDX license list %s; wrote it as the license name",
		fix.Path, fix.Written, list)
}
