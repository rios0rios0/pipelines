package entities

import (
	"slices"
	"strings"

	"github.com/rios0rios0/pipelines/global/scripts/languages/terraform/internal/text"
)

// prefixedTraversals are the reference forms that start with a keyword, in
// the order they are tried at a position: the keyword, how many names follow
// it, and the address the names build. A bare resource type is tried last.
func prefixedTraversals() []struct {
	keyword string
	parts   int
} {
	return []struct {
		keyword string
		parts   int
	}{
		{"local.", 1}, {"var.", 1}, {"data.", 2}, {"module.", 1}, {"check.", 1}, {"output.", 1},
	}
}

// reservedTypes can never be a resource type. All lack an underscore, so the
// bare-type form cannot match them anyway; the guard keeps a later loosening
// of that form correct.
func reservedTypes() map[string]bool {
	return map[string]bool{
		"each": true, "count": true, "self": true, "path": true, "terraform": true, "local": true, "var": true,
		kindModule: true, kindData: true, kindOutput: true, kindCheck: true, "run": true, "provider": true,
	}
}

// Traversals are the addresses a masked expression references: `local.x`,
// `var.x`, `data.t.n`, `module.x`, `check.x`, `output.x`, and `type.name` for
// a resource type -- lowercase, with at least one underscore, which is what
// keeps `each.value`, `self.id` and `p.name` out. A reference starts only
// where the character before it is neither a word character nor `.`, so
// `data.aws_ami.this` yields `data.aws_ami.this` and not also `aws_ami.this`;
// each name stops at the first character that cannot be in one, so
// `aws_rds_cluster_instance.main[0].id` yields `aws_rds_cluster_instance.main`.
func Traversals(expression string) map[string]bool {
	found := map[string]bool{}
	for at := 0; at < len(expression); {
		if !isASCIILetter(expression[at]) || !referenceMayStart(expression, at) {
			at++
			continue
		}
		address, end, ok := traversalAt(expression, at)
		if !ok {
			at++
			continue
		}
		if address != "" {
			found[address] = true
		}
		at = end
	}
	return found
}

func isASCIILetter(b byte) bool {
	return b >= 'a' && b <= 'z' || b >= 'A' && b <= 'Z'
}

// referenceMayStart is true at the start of `expression`, or after a
// character that is neither a word character nor `.`.
func referenceMayStart(expression string, at int) bool {
	previous, ok := text.RuneBefore(expression, at)
	return !ok || previous != '.' && !text.IsWord(previous)
}

// traversalAt reads the reference at `at`: its address -- empty for a
// reserved name, which is consumed without counting -- and where it ends.
func traversalAt(expression string, at int) (string, int, bool) {
	for _, form := range prefixedTraversals() {
		if !strings.HasPrefix(expression[at:], form.keyword) {
			continue
		}
		end := at + len(form.keyword)
		names := make([]string, 0, form.parts)
		for part := range form.parts {
			if part > 0 {
				if !strings.HasPrefix(expression[end:], ".") {
					break
				}
				end++
			}
			nameEnd := identifierEnd(expression, end)
			if nameEnd == end {
				break
			}
			names = append(names, expression[end:nameEnd])
			end = nameEnd
		}
		if len(names) == form.parts {
			return form.keyword + strings.Join(names, "."), end, true
		}
	}
	return resourceTraversal(expression, at)
}

// resourceTraversal reads `type.name` at `at`, `type` a resource type.
func resourceTraversal(expression string, at int) (string, int, bool) {
	typeEnd := at
	for typeEnd < len(expression) && isTypeByte(expression[typeEnd]) {
		typeEnd++
	}
	resourceType := expression[at:typeEnd]
	if !isResourceType(resourceType) || !strings.HasPrefix(expression[typeEnd:], ".") {
		return "", 0, false
	}
	nameEnd := identifierEnd(expression, typeEnd+1)
	if nameEnd == typeEnd+1 {
		return "", 0, false
	}
	if reservedTypes()[resourceType] {
		return "", nameEnd, true
	}
	return resourceType + "." + expression[typeEnd+1:nameEnd], nameEnd, true
}

func isTypeByte(b byte) bool {
	return b >= 'a' && b <= 'z' || b >= '0' && b <= '9' || b == '_'
}

// isResourceType is `[a-z][a-z0-9]*(_[a-z0-9]+)+`: a lowercase letter first,
// then segments joined by single underscores, at least two of them.
func isResourceType(candidate string) bool {
	if candidate == "" || candidate[0] < 'a' || candidate[0] > 'z' {
		return false
	}
	segments := strings.Split(candidate, "_")
	return len(segments) >= minimumTypeSegments && !slices.Contains(segments, "")
}

// minimumTypeSegments is the fewest underscore-joined segments a resource
// type has: `null_resource`, two.
const minimumTypeSegments = 2

// identifierEnd is the offset just past the identifier at `at` --
// `[A-Za-z_][A-Za-z0-9_-]*` -- or `at` itself when none starts there.
func identifierEnd(expression string, at int) int {
	if at >= len(expression) || !isASCIILetter(expression[at]) && expression[at] != '_' {
		return at
	}
	end := at + 1
	for end < len(expression) && (isASCIILetter(expression[end]) || isDigit(expression[end]) ||
		expression[end] == '_' || expression[end] == '-') {
		end++
	}
	return end
}

func isDigit(b byte) bool {
	return b >= '0' && b <= '9'
}
