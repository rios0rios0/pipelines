package reports

import (
	"fmt"
	"io"
	"strings"

	"github.com/rios0rios0/pipelines/global/scripts/tools/dependency-updates/internal/domain/commands"
	"github.com/rios0rios0/pipelines/global/scripts/tools/dependency-updates/internal/domain/entities"
)

// Console writes the run's progress lines: findings to `out`, refusals and
// errors to `errs`.
type Console struct {
	out  io.Writer
	errs io.Writer
}

// NewConsole builds the console.
func NewConsole(out, errs io.Writer) *Console {
	return &Console{out: out, errs: errs}
}

// Printf writes one line of progress.
func (c *Console) Printf(format string, arguments ...any) {
	_, _ = fmt.Fprintf(c.out, format, arguments...)
}

// Errorf writes one line of trouble.
func (c *Console) Errorf(format string, arguments ...any) {
	_, _ = fmt.Fprintf(c.errs, format, arguments...)
}

// Findings lists what the check found.
func (c *Console) Findings(check commands.CheckResult) {
	for _, task := range SortedTasks(check.Outdated()) {
		if task.Group == entities.GroupImage {
			c.Printf("  UPDATE  %-52s digest moved\n", task.Label)
		} else {
			c.Printf("  UPDATE  %-52s %s -> %s\n", task.Label, task.Current, task.Latest)
		}
	}
	for _, task := range SortedTasks(check.Vulnerable()) {
		c.Printf("  VULN    %-52s %s is affected by %s\n", task.Label, task.Security.Version,
			strings.Join(entities.AdvisoryIDs(task.Security.Current), ", "))
	}
	for _, task := range SortedTasks(check.Held()) {
		c.Printf("  HELD    %-52s %s is younger than the cooldown\n", task.Label, task.Selection.Held.Version)
	}
	for _, task := range SortedTasks(check.Tasks) {
		for _, rejection := range task.Selection.Rejected {
			c.Printf("  REJECT  %-52s %s: %s\n", task.Label, rejection.Version, rejection.Reason)
		}
	}
	for _, row := range check.Drift {
		c.Printf("  DRIFT   %-52s %s has %s, manifest says %s\n", row.Name, row.File, row.Inline, row.Manifest)
	}
	for _, row := range check.Untracked {
		c.Printf("  UNTRACKED %-50s no '# %s:' annotation\n", row.Name, row.Missing)
	}
}

// Applied lists what applying did.
func (c *Console) Applied(apply commands.ApplyResult) {
	for _, task := range SortedTasks(apply.Applied) {
		c.Printf("  APPLIED %-52s %s\n", task.Label, shown(task, task.Apply.New))
	}
	for _, fix := range apply.Fixes {
		c.Printf("  ALIGNED %-52s %s: %s -> %s\n", fix.Var, fix.File, fix.From, fix.To)
	}
	for _, task := range SortedTasks(apply.Refused) {
		c.Errorf("  REFUSED %-52s %s\n", task.Label, task.Refused)
	}
}

// Errors lists the lookups that failed.
func (c *Console) Errors(check commands.CheckResult) {
	for _, task := range check.Failed() {
		c.Errorf("  ERROR   %-52s %s\n", task.Label, task.Error)
	}
	if check.AdvisoryError != "" {
		c.Errorf("  ERROR   %-52s %s\n", "advisory database", check.AdvisoryError)
	}
}

// AssetChecks lists `--verify-assets` results.
func (c *Console) AssetChecks(checks []commands.AssetCheck) {
	for _, check := range checks {
		c.Printf("  %-9s %-36s %s\n", check.Status, check.Name, check.Detail)
	}
}
