// Package paths is how the Terraform helpers name, order and find files, in
// one place, so the four of them agree on which files they read and in what
// order they report them.
//
// Order is part of every report: findings, JUnit test cases and coverage files
// are listed in the order their paths sort. Paths sort component by component
// -- `a/b` before `a-c`, because `a` sorts before `a-c` -- not as one string,
// and a path is printed in its normalised form: no doubled `/`, no `.`
// component, no trailing `/`. A path is resolved the way the predecessors of
// these helpers resolved it, symlinks followed component by component and a
// component that does not exist kept as written, so a message naming a
// directory names it exactly as before.
package paths

import (
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
)

const (
	separator = "/"
	current   = "."
	parent    = ".."
)

// Getwd is the working directory with every symlink resolved: the directory
// the process is in, not the route a shell's `$PWD` took to get there.
func Getwd() (string, error) {
	wd, err := os.Getwd()
	if err != nil {
		return "", err
	}
	return filepath.EvalSymlinks(wd)
}

// step is one entry of the resolution stack: a path component still to
// resolve, or -- `link` set -- the marker recording that the symlink `name`
// has now been followed to its end.
type step struct {
	name string
	link bool
}

// Resolve makes `name` absolute and follows every symlink on the way, keeping
// a component that does not exist as written and leaving a symlink loop where
// it was found. It never fails for a path that does not exist; only an
// unreadable working directory makes it fail.
//
//nolint:gocognit // one loop over the resolution stack; splitting it hides the order symlinks are followed in
func Resolve(name string) (string, error) {
	resolved := separator
	if !strings.HasPrefix(name, separator) {
		wd, err := Getwd()
		if err != nil {
			return "", err
		}
		resolved = wd
	}
	stack := reversedSteps(name)
	pending := len(stack)
	seen := make(map[string]*string)
	for pending > 0 {
		next := stack[len(stack)-1]
		stack = stack[:len(stack)-1]
		if next.link {
			target := resolved
			seen[next.name] = &target
			continue
		}
		pending--
		switch next.name {
		case "", current:
			continue
		case parent:
			resolved = resolved[:strings.LastIndex(resolved, separator)]
			if resolved == "" {
				resolved = separator
			}
			continue
		}
		candidate := resolved + separator + next.name
		if resolved == separator {
			candidate = separator + next.name
		}
		info, err := os.Lstat(candidate)
		if err != nil || info.Mode()&fs.ModeSymlink == 0 {
			resolved = candidate
			continue
		}
		if target, known := seen[candidate]; known {
			resolved = candidate
			if target != nil {
				resolved = *target
			}
			continue
		}
		link, err := os.Readlink(candidate)
		if err != nil {
			resolved = candidate
			continue
		}
		seen[candidate] = nil
		if strings.HasPrefix(link, separator) {
			resolved = separator
		}
		stack = append(stack, step{name: candidate, link: true})
		parts := reversedSteps(link)
		stack = append(stack, parts...)
		pending += len(parts)
	}
	return resolved, nil
}

// reversedSteps are the components of `name`, last first, as a stack pops them.
func reversedSteps(name string) []step {
	components := strings.Split(name, separator)
	steps := make([]step, len(components))
	for i, component := range components {
		steps[len(components)-1-i] = step{name: component}
	}
	return steps
}

// Clean is `name` as it is printed: no doubled `/`, no `.` component, no
// trailing `/`, `..` kept. Exactly two leading slashes are kept, as POSIX
// allows them to mean something else than one; an empty name is `.`.
func Clean(name string) string {
	root := ""
	switch {
	case strings.HasPrefix(name, "//") && !strings.HasPrefix(name, "///"):
		root = "//"
	case strings.HasPrefix(name, separator):
		root = separator
	}
	var kept []string
	for component := range strings.SplitSeq(name, separator) {
		if component != "" && component != current {
			kept = append(kept, component)
		}
	}
	joined := root + strings.Join(kept, separator)
	if joined == "" {
		return current
	}
	return joined
}

// Join appends `name` to `base` as a path, `name` replacing `base` when it is
// absolute, and cleans the result.
func Join(base, name string) string {
	if strings.HasPrefix(name, separator) {
		return Clean(name)
	}
	return Clean(base + separator + name)
}

// components is what two paths are ordered by: their cleaned form, split.
func components(name string) []string {
	return strings.Split(Clean(name), separator)
}

// Compare orders two paths component by component; -1, 0 or +1.
func Compare(a, b string) int {
	return slices.Compare(components(a), components(b))
}

// Sort orders `names` the way every report lists files.
func Sort(names []string) {
	slices.SortFunc(names, Compare)
}

// Parts are the components of a cleaned path, the root as `/`.
func Parts(name string) []string {
	cleaned := Clean(name)
	var parts []string
	if strings.HasPrefix(cleaned, separator) {
		parts = append(parts, separator)
	}
	for component := range strings.SplitSeq(cleaned, separator) {
		if component != "" && component != current {
			parts = append(parts, component)
		}
	}
	return parts
}

// HasPart is true when a component of `name` -- an ancestor of a repository
// as much as anything inside it -- is one of `names`.
func HasPart(name string, names ...string) bool {
	for _, part := range Parts(name) {
		if slices.Contains(names, part) {
			return true
		}
	}
	return false
}

// Base is the last component of `name`.
func Base(name string) string {
	parts := Parts(name)
	if len(parts) == 0 {
		return ""
	}
	return parts[len(parts)-1]
}

// Dir is `name` without its last component.
func Dir(name string) string {
	cleaned := Clean(name)
	index := strings.LastIndex(cleaned, separator)
	switch {
	case index < 0:
		return current
	case index == 0:
		return separator
	case cleaned[:index] == separator:
		return "//"
	default:
		return cleaned[:index]
	}
}

// IsRelativeTo is true when `name` is `base` or below it, compared as written.
func IsRelativeTo(name, base string) bool {
	_, ok := RelativeTo(name, base)
	return ok
}

// RelativeTo is `name` relative to `base`, `.` when they are the same; false
// when `name` is not below `base`. Compared as written, never resolved.
func RelativeTo(name, base string) (string, bool) {
	nameParts, baseParts := Parts(name), Parts(base)
	if len(baseParts) > len(nameParts) || !slices.Equal(nameParts[:len(baseParts)], baseParts) {
		return "", false
	}
	rest := nameParts[len(baseParts):]
	if len(rest) == 0 {
		return current, true
	}
	return strings.Join(rest, separator), true
}

// IsFile is a regular file, following symlinks.
func IsFile(name string) bool {
	info, err := os.Stat(name)
	return err == nil && info.Mode().IsRegular()
}

// IsDir is a directory, following symlinks.
func IsDir(name string) bool {
	info, err := os.Stat(name)
	return err == nil && info.IsDir()
}

// Exists is anything that resolves, following symlinks.
func Exists(name string) bool {
	_, err := os.Stat(name)
	return err == nil
}

// IsSymlink is a symlink, whatever it points at.
func IsSymlink(name string) bool {
	info, err := os.Lstat(name)
	return err == nil && info.Mode()&fs.ModeSymlink != 0
}

// Children are the entries of a directory, sorted; none for one that cannot
// be listed.
func Children(dir string) []string {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil
	}
	children := make([]string, 0, len(entries))
	for _, entry := range entries {
		children = append(children, Join(dir, entry.Name()))
	}
	Sort(children)
	return children
}

// Glob are the entries of `dir` whose name matches `pattern`, hidden ones and
// dangling symlinks included, sorted.
func Glob(dir, pattern string) []string {
	matcher := Matcher(pattern)
	var found []string
	for _, child := range Children(dir) {
		if matcher.MatchString(Base(child)) {
			found = append(found, child)
		}
	}
	return found
}

// RGlob are the entries at any depth below `dir` whose name matches
// `pattern`, sorted. A directory that cannot be listed is skipped and a
// symlink is never descended into -- it is matched by its own name -- so a
// link cannot pull another tree, or the same one again, into the walk. Every
// directory named in `prune` is left out together with what it holds.
func RGlob(dir, pattern string, prune ...string) []string {
	matcher := Matcher(pattern)
	var found []string
	pending := []string{dir}
	for len(pending) > 0 {
		next := pending[len(pending)-1]
		pending = pending[:len(pending)-1]
		entries, err := os.ReadDir(next)
		if err != nil {
			continue
		}
		for _, entry := range entries {
			child := Join(next, entry.Name())
			if entry.IsDir() && slices.Contains(prune, entry.Name()) {
				continue
			}
			if matcher.MatchString(entry.Name()) {
				found = append(found, child)
			}
			if entry.IsDir() {
				pending = append(pending, child)
			}
		}
	}
	Sort(found)
	return found
}

// Match is true when `name` matches the shell-style `pattern`: `*` is any run
// of characters, `/` included, `?` is one character and `[...]` is a set,
// `[!...]` its complement. The whole name has to match.
func Match(name, pattern string) bool {
	return Matcher(pattern).MatchString(name)
}

// Matcher compiles a shell-style pattern, as [Match] reads it.
func Matcher(pattern string) *regexp.Regexp {
	return regexp.MustCompile(`(?s)\A` + translate([]rune(pattern)) + `\z`)
}

// translate turns a shell-style pattern into the regular expression it means.
func translate(pattern []rune) string {
	var b strings.Builder
	for i := 0; i < len(pattern); {
		switch pattern[i] {
		case '*':
			for i < len(pattern) && pattern[i] == '*' {
				i++
			}
			b.WriteString(".*")
		case '?':
			b.WriteString(".")
			i++
		case '[':
			class, next := translateSet(pattern, i+1)
			b.WriteString(class)
			i = next
		default:
			b.WriteString(regexp.QuoteMeta(string(pattern[i])))
			i++
		}
	}
	return b.String()
}

// translateSet turns the set that opened before `start` into a character
// class, and says where the pattern continues. A `[` with no closing `]` is a
// literal `[`. A range whose ends are reversed matches nothing, as does a set
// left empty once those are dropped; `[!]` matches any one character.
func translateSet(pattern []rune, start int) (string, int) {
	end := start
	if end < len(pattern) && pattern[end] == '!' {
		end++
	}
	if end < len(pattern) && pattern[end] == ']' {
		end++
	}
	for end < len(pattern) && pattern[end] != ']' {
		end++
	}
	if end >= len(pattern) {
		return `\[`, start
	}
	body := pattern[start:end]
	negated := len(body) > 0 && body[0] == '!'
	if negated {
		body = body[1:]
	}
	items := setItems(body)
	if len(items) == 0 {
		if negated {
			return ".", end + 1
		}
		return `[^\x00-\x{10FFFF}]`, end + 1
	}
	var b strings.Builder
	b.WriteByte('[')
	if negated {
		b.WriteByte('^')
	}
	for _, item := range items {
		b.WriteString(item)
	}
	b.WriteByte(']')
	return b.String(), end + 1
}

// setItems are the members of a set body, each a character or a range ready
// for a character class; reversed ranges are dropped.
func setItems(body []rune) []string {
	var items []string
	for i := 0; i < len(body); {
		if i+2 < len(body) && body[i+1] == '-' {
			if body[i] <= body[i+2] {
				items = append(items, quoteSetRune(body[i])+"-"+quoteSetRune(body[i+2]))
			}
			i += 3
			continue
		}
		items = append(items, quoteSetRune(body[i]))
		i++
	}
	return items
}

// quoteSetRune writes one character so a character class reads it literally.
func quoteSetRune(r rune) string {
	if strings.ContainsRune(`\]-^[`, r) {
		return `\` + string(r)
	}
	return regexp.QuoteMeta(string(r))
}
