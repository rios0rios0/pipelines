// Package filetext reads the repository's files as text the way the test
// suites report on them: which files a walk visits and in what order, what
// counts as a line, and what counts as a whole-line comment.
package filetext

import (
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"unicode"
)

// Walk visits every file under `root`, top-down: in each directory its files
// first, sorted by name, then its subdirectories, sorted by name, so a report
// lists its findings in the same order on every machine.
//
// A symbolic link to a file is visited as a file. A link to a directory is never
// entered, so no link can make a walk visit one tree twice or loop forever.
// `skip` names the directories not to enter at all; nil enters every one.
func Walk(root string, skip func(name string) bool, visit func(path string) error) error {
	entries, err := os.ReadDir(root)
	if err != nil {
		return err
	}
	var directories []string
	for _, entry := range entries {
		path := filepath.Join(root, entry.Name())
		switch classify(path, entry) {
		case linkedDirectory:
		case directory:
			if skip == nil || !skip(entry.Name()) {
				directories = append(directories, path)
			}
		case file:
			if err = visit(path); err != nil {
				return err
			}
		}
	}
	sort.Strings(directories)
	for _, directory := range directories {
		if err = Walk(directory, skip, visit); err != nil {
			return err
		}
	}
	return nil
}

// entryKind is how a walk treats one directory entry.
type entryKind int

const (
	file entryKind = iota
	directory
	linkedDirectory
)

// classify tells a real directory, which a walk enters, from a link to one,
// which it does not. Any other entry -- a link that resolves to nothing
// included -- is a file, which its visit then fails to read.
func classify(path string, entry fs.DirEntry) entryKind {
	if entry.Type()&fs.ModeSymlink == 0 {
		if entry.IsDir() {
			return directory
		}
		return file
	}
	if info, err := os.Stat(path); err == nil && info.IsDir() {
		return linkedDirectory
	}
	return file
}

// Read returns a file's text with every line break -- `\r\n`, a lone `\r` and
// `\n` -- written as `\n`.
func Read(path string) (string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	return NormalizeNewlines(string(data)), nil
}

// NormalizeNewlines writes every `\r\n` and lone `\r` in text as `\n`.
func NormalizeNewlines(text string) string {
	return strings.ReplaceAll(strings.ReplaceAll(text, "\r\n", "\n"), "\r", "\n")
}

// Lines splits text into its lines, without their terminators. A final
// terminator ends the last line rather than starting an empty one, so "a\n"
// is one line and "" is none.
func Lines(text string) []string {
	if text == "" {
		return nil
	}
	lines := strings.Split(NormalizeNewlines(text), "\n")
	if lines[len(lines)-1] == "" {
		lines = lines[:len(lines)-1]
	}
	return lines
}

// IsComment reports whether a line is a whole-line `#` comment: its first
// character that is not whitespace is `#`.
func IsComment(line string) bool {
	return strings.HasPrefix(strings.TrimLeftFunc(line, unicode.IsSpace), "#")
}

// StripComments drops every whole-line comment from text and joins the lines
// left with `\n`. This repository documents at length what its checks forbid,
// so a check that read the comments too would be failed by its own
// explanation.
func StripComments(text string) string {
	lines := Lines(text)
	kept := make([]string, 0, len(lines))
	for _, line := range lines {
		if !IsComment(line) {
			kept = append(kept, line)
		}
	}
	return strings.Join(kept, "\n")
}
