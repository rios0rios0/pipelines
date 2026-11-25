package entities

import (
	"fmt"
	"regexp"
	"strconv"
	"strings"
)

const (
	// PolicyFile is where a repository keeps its policy, at its root.
	PolicyFile = ".test-pyramid"
	// mixShares is how many shares a mix names: unit, integration, and functional and e2e.
	mixShares = 3
)

// Policy is a repository's `.test-pyramid`: whether a worsened pyramid fails the pull request, the
// reference mix, the suites to judge, and path rules applied before anything else the classifier
// knows. It is read from the TARGET branch, so a pull request is judged by the rules it is merged
// under and can neither loosen them nor reclassify its own tests around them.
type Policy struct {
	Blocking  bool
	Mix       Mix
	Languages []string
	Rules     []PathRule
}

// PolicyError is every problem of a `.test-pyramid`, each with its line.
type PolicyError struct {
	Problems []string
}

// DefaultPolicy is the policy of a repository without `.test-pyramid`: advisory, Software
// Engineering at Google's mix, the suite the pipeline names, no path rule.
func DefaultPolicy() Policy {
	return Policy{Mix: DefaultMix()}
}

// ParsePolicy reads a `.test-pyramid`: one setting per line, `#` starting a comment line.
//
//	blocking true|false                     whether a worsened pyramid fails the pull request
//	mix <unit>/<integration>/<large> | off  the reference mix, by test-case count
//	languages <name>...                     the suites to judge instead of the pipeline's
//	unit|integration|functional|e2e|ignore <regular expression>
//	                                        a path rule, the first one a path matches winning
//
// It is strict on purpose: a setting misspelt, set twice or given a value it does not take is a
// problem, never a setting quietly ignored, because an advisory check is what a typo in `blocking`
// would otherwise turn a blocking one into.
func ParsePolicy(text string) (Policy, error) {
	parser := &policyParser{policy: DefaultPolicy(), seen: map[string]bool{}}
	var problems []string
	for number, raw := range strings.Split(strings.ReplaceAll(text, "\r\n", "\n"), "\n") {
		line := strings.TrimSpace(raw)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		key, value, _ := strings.Cut(line, " ")
		if problem := parser.apply(key, strings.TrimSpace(value)); problem != "" {
			problems = append(problems, fmt.Sprintf("line %d: %s", number+1, problem))
		}
	}
	if len(problems) > 0 {
		return Policy{}, &PolicyError{Problems: problems}
	}
	return parser.policy, nil
}

// Error is every problem, one per line.
func (e *PolicyError) Error() string {
	return strings.Join(e.Problems, "\n")
}

// String is the policy as `.test-pyramid` would write it, which two policies equal when they say
// the same thing.
func (p Policy) String() string {
	lines := []string{
		"blocking " + strconv.FormatBool(p.Blocking),
		"mix " + p.Mix.String(),
		"languages " + strings.Join(p.Languages, " "),
	}
	for _, rule := range p.Rules {
		name := rule.Tier.String()
		if rule.Tier == TierIgnored {
			name = "ignore"
		}
		lines = append(lines, name+" "+rule.Pattern.String())
	}
	return strings.Join(lines, "\n")
}

// policyParser builds a Policy one `.test-pyramid` line at a time, remembering which settings it
// has seen so a second one is a problem.
type policyParser struct {
	policy Policy
	seen   map[string]bool
}

// apply sets one line's setting and returns its problem, or "" when it has none.
func (p *policyParser) apply(key, value string) string {
	if tier, known := ParseTier(key); known {
		return p.rule(tier, key, value)
	}
	setters := map[string]func(string) string{
		"blocking":  p.blocking,
		"mix":       p.mix,
		"languages": p.languages,
	}
	set, known := setters[key]
	if !known {
		return fmt.Sprintf(
			"unknown setting %q (known: blocking, mix, languages, unit, integration, functional, e2e, ignore)",
			key,
		)
	}
	if p.seen[key] {
		return fmt.Sprintf("%q is set twice", key)
	}
	p.seen[key] = true
	return set(value)
}

func (p *policyParser) rule(tier Tier, key, value string) string {
	if value == "" {
		return fmt.Sprintf("%q needs a regular expression for the paths it names", key)
	}
	pattern, err := regexp.Compile(value)
	if err != nil {
		return fmt.Sprintf("%q is not a valid regular expression: %v", value, err)
	}
	p.policy.Rules = append(p.policy.Rules, PathRule{Tier: tier, Pattern: pattern})
	return ""
}

func (p *policyParser) blocking(value string) string {
	switch value {
	case "true":
		p.policy.Blocking = true
	case "false":
		p.policy.Blocking = false
	default:
		return fmt.Sprintf("blocking is true or false, not %q", value)
	}
	return ""
}

func (p *policyParser) mix(value string) string {
	if value == "off" {
		p.policy.Mix = Mix{}
		return ""
	}
	parts := strings.Split(value, "/")
	shares := make([]int, 0, len(parts))
	for _, part := range parts {
		share, err := strconv.Atoi(part)
		if err != nil {
			break
		}
		shares = append(shares, share)
	}
	if len(parts) != mixShares || len(shares) != len(parts) {
		return fmt.Sprintf("mix is <unit>/<integration>/<functional and e2e> whole percentages, or off, not %q", value)
	}
	mix, err := NewMix(shares[0], shares[1], shares[2])
	if err != nil {
		return err.Error()
	}
	p.policy.Mix = mix
	return ""
}

func (p *policyParser) languages(value string) string {
	names := strings.Fields(value)
	if len(names) == 0 {
		return "languages names at least one suite"
	}
	for _, name := range names {
		if strings.ContainsFunc(name, func(r rune) bool { return r < 'a' || r > 'z' }) {
			return fmt.Sprintf("languages lists lower-case language names, not %q", name)
		}
	}
	p.policy.Languages = names
	return ""
}
