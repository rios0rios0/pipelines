package repositories

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

// gitDirectories are where git is run from: the system's own directories,
// which no job can write to. PATH is never consulted for it -- on a shared or
// self-hosted runner a directory a job CAN write to may come first in PATH, and
// whatever `git` it holds would run with this command's access to the
// repository.
func gitDirectories() []string {
	return []string{"/usr/bin", "/bin", "/usr/local/bin"}
}

// gitBinary is the first git found in gitDirectories.
func gitBinary() (string, error) {
	for _, directory := range gitDirectories() {
		candidate := filepath.Join(directory, "git")
		if info, err := os.Stat(candidate); err == nil && info.Mode().IsRegular() {
			return candidate, nil
		}
	}
	return "", fmt.Errorf("git was not found in %s", strings.Join(gitDirectories(), ", "))
}

const (
	gitTimeout = 30 * time.Second
	// mergeFileError is the exit status `git merge-file` reserves for a
	// failure; 1 to 127 count conflicts.
	mergeFileError = 255
)

// GitMergeRepository merges with `git merge-file`, the merge every reviewer of
// the result already trusts.
type GitMergeRepository struct{}

// NewGitMergeRepository builds the merger.
func NewGitMergeRepository() *GitMergeRepository {
	return &GitMergeRepository{}
}

// Merge applies the change from `base` to `theirs` onto `ours`.
func (r *GitMergeRepository) Merge(ours, base, theirs string) (string, int, error) {
	directory, err := os.MkdirTemp("", "dependency-updates-merge-")
	if err != nil {
		return "", 0, err
	}
	defer func() { _ = os.RemoveAll(directory) }()
	for name, content := range map[string]string{"ours": ours, "base": base, "theirs": theirs} {
		if writeErr := os.WriteFile(filepath.Join(directory, name), []byte(content), newFileMode); writeErr != nil {
			return "", 0, writeErr
		}
	}
	git, err := gitBinary()
	if err != nil {
		return "", 0, err
	}
	ctx, cancel := context.WithTimeout(context.Background(), gitTimeout)
	defer cancel()
	command := exec.CommandContext(ctx, git, "merge-file", "-p", "-L", "ours", "-L", "base", "-L", "theirs",
		"ours", "base", "theirs")
	command.Dir = directory
	var stdout, stderr bytes.Buffer
	command.Stdout, command.Stderr = &stdout, &stderr
	err = command.Run()
	var exit *exec.ExitError
	switch {
	case err == nil:
		return stdout.String(), 0, nil
	case errors.As(err, &exit) && exit.ExitCode() > 0 && exit.ExitCode() < mergeFileError:
		return stdout.String(), exit.ExitCode(), nil
	default:
		return "", 0, fmt.Errorf("git merge-file: %w: %s", err, strings.TrimSpace(stderr.String()))
	}
}

// GitHistoryRepository reads the scanned repository's history.
type GitHistoryRepository struct {
	root string
}

// NewGitHistoryRepository builds the reader for the repository at `root`.
func NewGitHistoryRepository(root string) *GitHistoryRepository {
	return &GitHistoryRepository{root: root}
}

// HeadCommitTime is when HEAD was committed.
func (r *GitHistoryRepository) HeadCommitTime() (time.Time, error) {
	git, err := gitBinary()
	if err != nil {
		return time.Time{}, err
	}
	ctx, cancel := context.WithTimeout(context.Background(), gitTimeout)
	defer cancel()
	command := exec.CommandContext(ctx, git, "log", "-1", "--format=%cI", "HEAD")
	command.Dir = r.root
	output, err := command.Output()
	if err != nil {
		return time.Time{}, err
	}
	return time.Parse(time.RFC3339, strings.TrimSpace(string(output)))
}
