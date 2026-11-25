package repositories

import (
	"bufio"
	"bytes"
	"errors"
	"fmt"
	"io"
	"strconv"
	"strings"

	"github.com/rios0rios0/pipelines/global/scripts/tools/test-pyramid/internal/domain/entities"
)

const (
	// maxFileSize is the largest file read; a larger one is no hand-written test file.
	maxFileSize = 16 << 20
	// binarySniff is how much of a file git's own heuristic reads for a NUL to call it binary.
	binarySniff = 8000
	// regularFile and executableFile are the modes of a blob that is a file, not a link.
	regularFile    = "100644"
	executableFile = "100755"
	// treeFields is `<mode> <type> <object>` before the tab of a `git ls-tree` entry.
	treeFields = 3
)

// GitTreesRepository reads a commit's tree with `git ls-tree` and `git cat-file`, so a tree is
// never checked out and both trees of a pull request come from the same working copy.
type GitTreesRepository struct {
	git *gitRunner
}

// NewGitTreesRepository reads the working copy at `directory`.
func NewGitTreesRepository(directory string) (*GitTreesRepository, error) {
	git, err := newGitRunner(directory)
	if err != nil {
		return nil, err
	}
	return &GitTreesRepository{git: git}, nil
}

// FindFileByPath is a file's content at a commit, and whether the commit holds it as a regular
// file. Absence is an empty listing and a git that fails is an error, so a failure can never be
// read as "no such file" -- for `.test-pyramid`, as an advisory policy nobody wrote.
func (r *GitTreesRepository) FindFileByPath(commit, path string) (string, bool, error) {
	listing, err := r.git.raw("ls-tree", "-z", "--full-tree", commit, "--", path)
	if err != nil {
		return "", false, err
	}
	header, _, listed := strings.Cut(strings.TrimSuffix(listing, "\x00"), "\t")
	fields := strings.Fields(header)
	if !listed || len(fields) != treeFields || (fields[0] != regularFile && fields[0] != executableFile) {
		return "", false, nil
	}
	content, err := r.git.raw("cat-file", "blob", fields[2])
	if err != nil {
		return "", true, err
	}
	return content, true, nil
}

// FindAllFilesByFilter are the regular files of a commit that `keep` accepts, with their content,
// in path order; a binary file, a link or a submodule is left out.
func (r *GitTreesRepository) FindAllFilesByFilter(
	commit string,
	keep func(path string) bool,
) ([]entities.TestFile, error) {
	listing, err := r.git.raw("ls-tree", "-r", "-z", "--full-tree", commit)
	if err != nil {
		return nil, err
	}
	var paths, objects []string
	for entry := range strings.SplitSeq(listing, "\x00") {
		header, path, found := strings.Cut(entry, "\t")
		fields := strings.Fields(header)
		if !found || len(fields) != treeFields || (fields[0] != regularFile && fields[0] != executableFile) ||
			!keep(path) {
			continue
		}
		paths = append(paths, path)
		objects = append(objects, fields[2])
	}
	files := []entities.TestFile{}
	if len(objects) == 0 {
		return files, nil
	}
	contents, err := r.contents(objects)
	if err != nil {
		return nil, err
	}
	for index, content := range contents {
		if content != nil && !bytes.Contains(content[:min(len(content), binarySniff)], []byte{0}) {
			files = append(files, entities.TestFile{Path: paths[index], Content: string(content)})
		}
	}
	return files, nil
}

// contents are the objects' contents through one `git cat-file --batch`, in their order; an object
// too large to be a test file is nil.
func (r *GitTreesRepository) contents(objects []string) ([][]byte, error) {
	command, cancel := r.git.command("cat-file", "--batch")
	defer cancel()
	stdin, err := command.StdinPipe()
	if err != nil {
		return nil, err
	}
	stdout, err := command.StdoutPipe()
	if err != nil {
		return nil, err
	}
	var stderr bytes.Buffer
	command.Stderr = &stderr
	if err = command.Start(); err != nil {
		return nil, err
	}
	// Written beside the reads: git answers as it is asked, and a request it cannot write back
	// while nothing reads would stop both sides.
	go func() {
		_, _ = io.WriteString(stdin, strings.Join(objects, "\n")+"\n")
		_ = stdin.Close()
	}()
	contents, readErr := readBatch(bufio.NewReader(stdout), len(objects))
	waitErr := command.Wait()
	if readErr != nil {
		return nil, readErr
	}
	if waitErr != nil {
		return nil, fmt.Errorf("git cat-file: %w: %s", waitErr, tail(stderr.String()))
	}
	return contents, nil
}

// readBatch reads `count` answers of `git cat-file --batch`: `<object> <type> <size>`, the content
// and a newline each.
func readBatch(reader *bufio.Reader, count int) ([][]byte, error) {
	contents := make([][]byte, 0, count)
	for range count {
		header, err := reader.ReadString('\n')
		if err != nil {
			return nil, fmt.Errorf("git cat-file stopped answering: %w", err)
		}
		fields := strings.Fields(header)
		if len(fields) != treeFields {
			return nil, errors.New("git cat-file could not read an object of the tree: " + strings.TrimSpace(header))
		}
		size, err := strconv.Atoi(fields[2])
		if err != nil {
			return nil, fmt.Errorf("git cat-file answered %q: %w", strings.TrimSpace(header), err)
		}
		if size > maxFileSize {
			if _, err = reader.Discard(size + 1); err != nil {
				return nil, err
			}
			contents = append(contents, nil)
			continue
		}
		content := make([]byte, size+1)
		if _, err = io.ReadFull(reader, content); err != nil {
			return nil, fmt.Errorf("git cat-file stopped in an object: %w", err)
		}
		contents = append(contents, content[:size])
	}
	return contents, nil
}
