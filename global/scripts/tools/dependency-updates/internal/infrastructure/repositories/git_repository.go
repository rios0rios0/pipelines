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
	ctx, cancel := context.WithTimeout(context.Background(), gitTimeout)
	defer cancel()
	command := exec.CommandContext(ctx, "git", "merge-file", "-p", "-L", "ours", "-L", "base", "-L", "theirs",
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
	ctx, cancel := context.WithTimeout(context.Background(), gitTimeout)
	defer cancel()
	command := exec.CommandContext(ctx, "git", "log", "-1", "--format=%cI", "HEAD")
	command.Dir = r.root
	output, err := command.Output()
	if err != nil {
		return time.Time{}, err
	}
	return time.Parse(time.RFC3339, strings.TrimSpace(string(output)))
}
