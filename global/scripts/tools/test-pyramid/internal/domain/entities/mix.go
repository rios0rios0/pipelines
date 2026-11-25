package entities

import "fmt"

const (
	// percent is a whole: the three shares of a mix add up to it.
	percent = 100
	// defaultUnitShare, defaultIntegrationShare and defaultLargeShare are Software Engineering at
	// Google's mix, by test-case count: "around 80% of our tests being narrow-scoped unit tests ...
	// 15% medium-scoped integration tests ... and 5% end-to-end tests that validate the entire
	// system" (chapter 11, "Test Scope"), "a very rough guideline".
	defaultUnitShare        = 80
	defaultIntegrationShare = 15
	defaultLargeShare       = 5
)

// Mix is a reference proportion of a suite's test cases by scope, in whole percentages: unit
// (narrow), integration (medium), and functional and e2e together (large), the three scopes
// Software Engineering at Google names, which groups "functional tests, end-to-end tests, or
// system tests" in the large one. A mix that is not Judged (`mix off`) leaves the shape alone to
// judge a suite.
type Mix struct {
	Unit        int
	Integration int
	Large       int
	Judged      bool
}

// DefaultMix is Software Engineering at Google's: 80% unit, 15% integration, 5% functional and e2e.
func DefaultMix() Mix {
	return Mix{Unit: defaultUnitShare, Integration: defaultIntegrationShare, Large: defaultLargeShare, Judged: true}
}

// NewMix is a judged mix of the three shares, refused unless they add up to 100.
func NewMix(unit, integration, large int) (Mix, error) {
	if unit < 0 || integration < 0 || large < 0 || unit+integration+large != percent {
		return Mix{}, fmt.Errorf("the mix percentages %d/%d/%d do not add up to 100", unit, integration, large)
	}
	return Mix{Unit: unit, Integration: integration, Large: large, Judged: true}, nil
}

// String is the mix as `.test-pyramid` writes it.
func (m Mix) String() string {
	if !m.Judged {
		return "off"
	}
	return fmt.Sprintf("%d/%d/%d", m.Unit, m.Integration, m.Large)
}

// Limit is the most, in percent of a suite, the mix leaves the test cases at or above `tier`: the
// integration share and the large one for integration and above, the large share for functional
// and e2e. Below integration nothing is limited.
func (m Mix) Limit(tier Tier) int {
	if tier >= TierFunctional {
		return m.Large
	}
	if tier == TierIntegration {
		return m.Integration + m.Large
	}
	return percent
}

// Allowance is how many of `total` test cases the mix leaves the tiers at or above `tier`, rounded
// up to a whole test case, so a small suite is never failed for holding one.
func (m Mix) Allowance(tier Tier, total int) int {
	return (m.Limit(tier)*total + percent - 1) / percent
}
