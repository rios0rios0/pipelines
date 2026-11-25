package entities

// Counts are the test cases of a suite in each tier, indexed by the tier.
type Counts [tierCount]int

// Of is the test cases in one tier.
func (c Counts) Of(tier Tier) int {
	return c[tier]
}

// Total is every test case the pyramid counts, the ignored ones left out.
func (c Counts) Total() int {
	total := 0
	for _, tier := range Tiers() {
		total += c[tier]
	}
	return total
}

// Below is the test cases in every tier below `tier`.
func (c Counts) Below(tier Tier) int {
	below := 0
	for _, lower := range Tiers() {
		if lower < tier {
			below += c[lower]
		}
	}
	return below
}

// AtOrAbove is the test cases in `tier` and in every tier above it.
func (c Counts) AtOrAbove(tier Tier) int {
	return c.Total() - c.Below(tier)
}

// Excess is how many more test cases `tier` holds than every tier below it combined, 0 when it
// holds no more.
func (c Counts) Excess(tier Tier) int {
	return max(c[tier]-c.Below(tier), 0)
}
