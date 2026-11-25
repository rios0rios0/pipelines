// Package repositories reads a repository through git, the implementations of the domain's ports.
package repositories

import (
	"bytes"
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

const (
	// gitTimeout bounds one git command reading the repository.
	gitTimeout = 10 * time.Minute
	// errorTail is how much of git's error output an error quotes.
	errorTail = 600
)

// gitDirectories are where git is run from: the system's own directories, which no job can write
// to. PATH is never consulted for it -- on a shared or self-hosted runner a directory a job CAN
// write to may come first in PATH, and whatever `git` it holds would run with this check's access
// to the repository and the credentials its checkout persisted.
func gitDirectories() []string {
	return []string{"/usr/bin", "/bin", "/usr/local/bin"}
}

// gitRunner runs git in one working copy, never prompting for a credential.
type gitRunner struct {
	binary    string
	directory string
}

// newGitRunner finds git in gitDirectories, to run in `directory`.
func newGitRunner(directory string) (*gitRunner, error) {
	for _, candidate := range gitDirectories() {
		binary := filepath.Join(candidate, "git")
		if info, err := os.Stat(binary); err == nil && info.Mode().IsRegular() {
			return &gitRunner{binary: binary, directory: directory}, nil
		}
	}
	return nil, fmt.Errorf("git was not found in %s", strings.Join(gitDirectories(), ", "))
}

// FindRepositoryRoot is the top of the working copy `directory` lies in.
func FindRepositoryRoot(directory string) (string, error) {
	git, err := newGitRunner(directory)
	if err != nil {
		return "", err
	}
	top, err := git.output("rev-parse", "--show-toplevel")
	if err != nil {
		return "", fmt.Errorf("not inside a git repository: %w", err)
	}
	return top, nil
}

// output is what a git command prints, its trailing newline removed.
func (g *gitRunner) output(arguments ...string) (string, error) {
	stdout, err := g.raw(arguments...)
	return strings.TrimRight(stdout, "\n"), err
}

// raw is what a git command prints, as it prints it.
func (g *gitRunner) raw(arguments ...string) (string, error) {
	command, cancel := g.command(arguments...)
	defer cancel()
	var stdout, stderr bytes.Buffer
	command.Stdout, command.Stderr = &stdout, &stderr
	if err := command.Run(); err != nil {
		return stdout.String(), fmt.Errorf("git %s: %w: %s", arguments[0], err, tail(stderr.String()))
	}
	return stdout.String(), nil
}

// command is a git command in the working copy with no prompt and a timeout; the cancel function
// releases it.
func (g *gitRunner) command(arguments ...string) (*exec.Cmd, context.CancelFunc) {
	ctx, cancel := context.WithTimeout(context.Background(), gitTimeout)
	//nolint:gosec // G204: git is resolved from the system's directories, and every argument is an argument, never a shell word
	command := exec.CommandContext(ctx, g.binary, append([]string{"-C", g.directory}, arguments...)...)
	command.Env = append(os.Environ(), "GIT_TERMINAL_PROMPT=0", "LC_ALL=C")
	return command, cancel
}

// tail is the end of git's error output, on one line.
func tail(text string) string {
	text = strings.Join(strings.Fields(text), " ")
	if len(text) > errorTail {
		return "..." + text[len(text)-errorTail:]
	}
	return text
}
