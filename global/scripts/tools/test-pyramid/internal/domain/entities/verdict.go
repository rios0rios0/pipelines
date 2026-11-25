package entities

import "fmt"

// Shape is what a suite looks like, in the words of the book.
type Shape string

const (
	// ShapeNoTests is a suite with no test case to judge.
	ShapeNoTests Shape = "no tests"
	// ShapePyramid keeps both rules: no tier outnumbers the tiers below it, and the reference mix.
	ShapePyramid Shape = "pyramid"
	// ShapeIceCreamCone is a suite where a tier outnumbers every tier below it combined: Google's
	// "inverted pyramid/ice cream cone", which "relies primarily on end-to-end tests, using few
	// integration tests and even fewer unit tests".
	ShapeIceCreamCone Shape = "ice-cream cone"
	// ShapeHourglass is a suite past the reference mix's large share whose integration tier is
	// thinner than the functional and e2e tests above it: "many end-to-end tests and many unit
	// tests but few integration tests" (Software Engineering at Google, chapter 11).
	ShapeHourglass Shape = "hourglass"
	// ShapeTopHeavy is any other suite past the reference mix.
	ShapeTopHeavy Shape = "top-heavy"
)

// Verdict is what a pull request does to one suite's pyramid: its test cases on the target branch
// and with the pull request, the mix it was judged by, and what it worsened.
type Verdict struct {
	Language    string
	Mix         Mix
	Target      Counts
	PullRequest Counts
	Findings    []string
}

// Judge compares a suite on the target branch with the same suite after the pull request, by two
// rules from the book and a ratchet over each.
//
// SHAPE: no tier holds more test cases than every tier below it combined. "The more high-level you
// get the fewer tests you should have" (Ham Vocke, The Practical Test Pyramid); "you should have
// many more low-level UnitTests than high level BroadStackTests" (Martin Fowler, TestPyramid). It
// is measured against the sum of the lower tiers, not the tier right below, so a project that
// uses no functional tier is not condemned for a tier it does not use; the mix catches the
// hourglass, the one shape this lets through.
//
// MIX: the suite stays within the reference mix, at two boundaries -- integration and above, and
// functional and e2e -- each allowance rounded up to a whole test case.
//
// RATCHET: a pull request is held only to what it WORSENS. A tier's excess over the tiers below it
// may not grow, and past a boundary, the boundary's share of the suite may not grow; a target
// branch that already breaks a rule may be left as it is, or improved.
//
// Every comparison is between whole numbers: a share is compared as a cross-product, never as a
// ratio, so the verdict is the same on every machine.
func Judge(language string, target, pullRequest Counts, mix Mix) Verdict {
	verdict := Verdict{Language: language, Mix: mix, Target: target, PullRequest: pullRequest}
	for _, tier := range Tiers()[1:] {
		before, after := target.Excess(tier), pullRequest.Excess(tier)
		if after > before {
			was := "not at all"
			if before > 0 {
				was = fmt.Sprintf("by %d", before)
			}
			verdict.Findings = append(verdict.Findings, fmt.Sprintf(
				"%s tests now outnumber every tier below them combined by %d (%s on the target branch)",
				tier, after, was))
		}
	}
	if !mix.Judged {
		return verdict
	}
	for _, boundary := range boundaries() {
		if !mix.past(pullRequest, boundary.tier) || !grew(target, pullRequest, boundary.tier) {
			continue
		}
		verdict.Findings = append(verdict.Findings, fmt.Sprintf(
			"%s are now %s of the suite, above the %d%% the reference mix leaves them (%s on the target branch)",
			boundary.name, Share(pullRequest.AtOrAbove(boundary.tier), pullRequest.Total()),
			mix.Limit(boundary.tier), Share(target.AtOrAbove(boundary.tier), target.Total())))
	}
	return verdict
}

// Share is `part` as a percentage of `total`, to one decimal, or `-` when there is no total.
func Share(part, total int) string {
	if total == 0 {
		return "-"
	}
	return fmt.Sprintf("%.1f%%", float64(part)*percent/float64(total))
}

// Worsened is whether the pull request worsens the suite's pyramid.
func (v Verdict) Worsened() bool {
	return len(v.Findings) > 0
}

// TargetShape is the suite's shape on the target branch.
func (v Verdict) TargetShape() Shape {
	return shapeOf(v.Target, v.Mix)
}

// PullRequestShape is the suite's shape with the pull request.
func (v Verdict) PullRequestShape() Shape {
	return shapeOf(v.PullRequest, v.Mix)
}

// boundary is a share of the suite the reference mix limits: the test cases at or above a tier.
type boundary struct {
	tier Tier
	name string
}

func boundaries() []boundary {
	return []boundary{
		{tier: TierIntegration, name: "integration, functional and e2e tests"},
		{tier: TierFunctional, name: "functional and e2e tests"},
	}
}

// past is whether the suite holds more test cases at or above `tier` than the mix allows them.
func (m Mix) past(counts Counts, tier Tier) bool {
	return m.Judged && counts.AtOrAbove(tier) > m.Allowance(tier, counts.Total())
}

// grew is whether the share of the suite at or above `tier` is larger after than before, compared
// as cross-products. A target branch with no test case had a share of none.
func grew(before, after Counts, tier Tier) bool {
	if before.Total() == 0 {
		return after.AtOrAbove(tier) > 0
	}
	return after.AtOrAbove(tier)*before.Total() > before.AtOrAbove(tier)*after.Total()
}

func shapeOf(counts Counts, mix Mix) Shape {
	if counts.Total() == 0 {
		return ShapeNoTests
	}
	for _, tier := range Tiers()[1:] {
		if counts.Excess(tier) > 0 {
			return ShapeIceCreamCone
		}
	}
	pastLarge := mix.past(counts, TierFunctional)
	if pastLarge && counts.Of(TierIntegration) < counts.AtOrAbove(TierFunctional) {
		return ShapeHourglass
	}
	if pastLarge || mix.past(counts, TierIntegration) {
		return ShapeTopHeavy
	}
	return ShapePyramid
}
