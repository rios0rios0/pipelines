package repositories

import (
	"bytes"
	"context"
	"errors"
	"os/exec"
	"strconv"
	"syscall"

	"github.com/rios0rios0/pipelines/global/scripts/languages/terraform/internal/text"
)

// TerraformFormatter runs `terraform fmt` over a module's `tests/`.
type TerraformFormatter struct {
	root string
}

// NewTerraformFormatter formats the module at `root`.
func NewTerraformFormatter(root string) *TerraformFormatter {
	return &TerraformFormatter{root: root}
}

// Format runs `terraform -chdir=<root> fmt tests/` from argv, never a shell,
// so a path with spaces cannot break it and one with shell syntax cannot run
// anything. A missing `terraform`, or one that fails, is a warning.
func (f *TerraformFormatter) Format() string {
	binary, err := exec.LookPath("terraform")
	if err != nil {
		return "terraform not on PATH; skipping `terraform fmt` on generated file"
	}
	var stderr bytes.Buffer
	command := exec.CommandContext(context.Background(), binary, "-chdir="+f.root, "fmt", "tests/")
	command.Stderr = &stderr
	err = command.Run()
	if err == nil {
		return ""
	}
	return "`terraform fmt` exited " + exitStatus(command, err) + ": " + text.Strip(text.Normalise(stderr.String()))
}

// exitStatus is how a finished command exited: its status, or minus the
// signal that killed it.
func exitStatus(command *exec.Cmd, err error) string {
	var exitError *exec.ExitError
	if !errors.As(err, &exitError) {
		return "-1"
	}
	if status, ok := command.ProcessState.Sys().(syscall.WaitStatus); ok && status.Signaled() {
		return strconv.Itoa(-int(status.Signal()))
	}
	return strconv.Itoa(exitError.ExitCode())
}
