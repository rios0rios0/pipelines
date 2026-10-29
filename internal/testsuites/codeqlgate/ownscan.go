package main

import (
	"fmt"
	"io"
	"path/filepath"
	"regexp"
	"sort"
	"strings"

	"github.com/rios0rios0/pipelines/internal/testsuites/filetext"
	"github.com/rios0rios0/pipelines/internal/testsuites/yamldoc"
)

var (
	// datedRationale is the comment line a suppression's reason starts with.
	datedRationale = regexp.MustCompile(`^# [0-9]{4}-[0-9]{2}-[0-9]{2} -- `)
	// bareFingerprint is the only line shape the gate matches a finding by.
	bareFingerprint = regexp.MustCompile(`^[0-9a-f]+:[0-9]+$`)
)

// excludedQuery is the one query this repository's own scan may drop.
const excludedQuery = "actions/unpinned-tag"

// checkOwnScan holds the two places a finding of this repository's own scan
// can be made to disappear -- the root `codeql-config.yml` and
// `.codeql-false-positives` -- to exactly what their comments justify, and the
// consumers' default suppressions to nothing.
func checkOwnScan(root string, output io.Writer) error {
	var findings []string
	config, err := yamldoc.Load(filepath.Join(root, "codeql-config.yml"), yamldoc.Options{})
	if err != nil {
		return err
	}
	if keys := sortedKeys(config); len(keys) != 1 || keys[0] != yamldoc.Quote("query-filters") {
		findings = append(findings, "codeql-config.yml sets more than query-filters: ["+strings.Join(keys, ", ")+"]")
	}
	if filters := config.Get("query-filters"); !excludesOnlyUnpinnedTag(filters) {
		findings = append(findings, "codeql-config.yml filters more than "+excludedQuery+": "+filters.Repr())
	}
	suppressions, err := filetext.Read(filepath.Join(root, ".codeql-false-positives"))
	if err != nil {
		return err
	}
	findings = append(findings, suppressionFindings(suppressions)...)
	defaults, err := filetext.Read(filepath.Join(root, "global/scripts/tools/codeql/.codeql-false-positives"))
	if err != nil {
		return err
	}
	for number, line := range filetext.Lines(defaults) {
		if strings.TrimSpace(line) != "" && !filetext.IsComment(line) {
			findings = append(findings, fmt.Sprintf("the consumers' default .codeql-false-positives lists line %d: %s",
				number+1, yamldoc.Quote(strings.TrimSpace(line))))
		}
	}
	for _, finding := range findings {
		if _, err = fmt.Fprintln(output, finding); err != nil {
			return err
		}
	}
	return nil
}

// sortedKeys are a mapping's keys, rendered and sorted.
func sortedKeys(node *yamldoc.Node) []string {
	pairs := append([]yamldoc.Pair(nil), node.Pairs()...)
	sort.SliceStable(pairs, func(i, j int) bool { return pairs[i].Key.Str() < pairs[j].Key.Str() })
	keys := make([]string, 0, len(pairs))
	for _, pair := range pairs {
		keys = append(keys, pair.Key.Repr())
	}
	return keys
}

// excludesOnlyUnpinnedTag reports whether the filters are exactly
// `[{exclude: {id: actions/unpinned-tag}}]`.
func excludesOnlyUnpinnedTag(filters *yamldoc.Node) bool {
	items := filters.Items()
	if len(items) != 1 {
		return false
	}
	exclude := items[0].Pairs()
	if len(exclude) != 1 || !exclude[0].Key.Is("exclude") {
		return false
	}
	id := exclude[0].Value.Pairs()
	return len(id) == 1 && id[0].Key.Is("id") && id[0].Value.Is(excludedQuery)
}

// suppressionFindings holds every suppression to a bare fingerprint -- the
// only shape that silences anything -- under a dated rationale.
func suppressionFindings(text string) []string {
	var findings []string
	dated := false
	for index, line := range filetext.Lines(text) {
		if datedRationale.MatchString(line) {
			dated = true
		}
		if strings.TrimSpace(line) == "" || filetext.IsComment(line) {
			continue
		}
		switch {
		case !bareFingerprint.MatchString(line):
			findings = append(findings, fmt.Sprintf(
				".codeql-false-positives:%d is not a bare fingerprint, so it silences nothing: %s",
				index+1, yamldoc.Quote(line)))
		case !dated:
			findings = append(
				findings,
				fmt.Sprintf(".codeql-false-positives:%d has no dated rationale above it", index+1),
			)
		}
	}
	return findings
}
