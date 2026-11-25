// Package entities is the test pyramid's model: the tiers, the rules that put a test case in one,
// a repository's policy, and the verdict on what a pull request does to its suite.
package entities

// Tier is the place of a test case in the pyramid. The tiers are ordered by SCOPE -- how much of
// the system a test exercises -- the axis Software Engineering at Google (chapter 11, "Test
// Scope") draws its pyramid on: a unit test validates a small, focused part of the code; an
// integration test the interactions between a small number of components; a functional test the
// application through its public interface, below the UI (Martin Fowler's subcutaneous test); an
// end-to-end test the whole system through its outermost interface (his broad-stack test).
type Tier int

const (
	// TierIgnored is a test file the repository's own rules leave out of the pyramid.
	TierIgnored Tier = iota
	// TierUnit is a narrow-scoped test: one unit in one process, with no I/O.
	TierUnit
	// TierIntegration is a medium-scoped test: a unit with a real collaborator beyond its process,
	// such as a database, a container or a server on localhost.
	TierIntegration
	// TierFunctional is a large-scoped test below the UI: the application booted and driven through
	// its public interface, its HTTP routes, its CLI or its message handlers.
	TierFunctional
	// TierE2E is a large-scoped test through the outermost interface: the system driven through
	// its UI, a browser or a device.
	TierE2E
)

// tierCount is how many tiers there are, the ignored one included: the length of anything indexed
// by a tier.
const tierCount = int(TierE2E) + 1

// Tiers are the tiers of the pyramid, bottom to top.
func Tiers() []Tier {
	return []Tier{TierUnit, TierIntegration, TierFunctional, TierE2E}
}

// ParseTier is the tier a name in `.test-pyramid` stands for, `ignore` naming TierIgnored.
func ParseTier(name string) (Tier, bool) {
	if name == "ignore" {
		return TierIgnored, true
	}
	for _, tier := range Tiers() {
		if tier.String() == name {
			return tier, true
		}
	}
	return TierIgnored, false
}

// tierNames is every tier's name in `.test-pyramid` and in every report.
func tierNames() map[Tier]string {
	return map[Tier]string{
		TierIgnored:     "ignored",
		TierUnit:        "unit",
		TierIntegration: "integration",
		TierFunctional:  "functional",
		TierE2E:         "e2e",
	}
}

// String is the tier's name.
func (t Tier) String() string {
	if name, known := tierNames()[t]; known {
		return name
	}
	return "unknown"
}
