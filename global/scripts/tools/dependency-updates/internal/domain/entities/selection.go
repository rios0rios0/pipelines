package entities

import (
	"slices"
	"strings"
	"time"
)

// Day is a cooldown's unit.
const Day = 24 * time.Hour

// DefaultCooldown is how old a release must be before it is proposed.
//
// Most supply-chain compromises of the last two years were caught and pulled
// within hours to days of publication (tj-actions/changed-files, the September
// 2025 npm account takeovers, ultralytics): an advisory database cannot know
// about a release hijacked an hour ago, but a week is long enough for most to
// be found. Seven days is the figure that analysis recommends; Dependabot's own
// default is three, and it waives the wait for security updates, as this does.
const DefaultCooldown = 7 * Day

// Release is one published version of an upstream dependency.
type Release struct {
	Version string
	// Published is when the release became available; zero when the upstream
	// does not say, which never satisfies a cooldown.
	Published  time.Time
	Prerelease bool
}

// Candidate is a release a pin could move to, with the known advisories that
// affect it.
type Candidate struct {
	Release

	Advisories []Advisory
}

// Rejection is a candidate the policy refused, and why.
type Rejection struct {
	Version string
	Reason  string
}

// Selection is the release the policy proposes for one pin, and what it knows
// about the choice.
type Selection struct {
	// Target is the release to move to; nil when nothing may be proposed.
	Target *Candidate
	// Waived is true when the target is younger than the cooldown, proposed
	// anyway because it fixes known advisories on the pin in use today.
	Waived bool
	// Held is the newest release the cooldown kept back, when there was one.
	Held *Release
	// Rejected lists candidates refused for their advisories.
	Rejected []Rejection
	// Fixed are the current pin's advisories the target resolves.
	Fixed []Advisory
	// Remaining are the current pin's advisories the target still has; when
	// there is no target, every one of them.
	Remaining []Advisory
}

// SelectionPolicy decides which release a pin moves to.
type SelectionPolicy struct {
	Now      time.Time
	Cooldown time.Duration
}

// Aged is true when the release has been public for the whole cooldown.
func (p SelectionPolicy) Aged(release Release) bool {
	if p.Cooldown <= 0 {
		return true
	}
	if release.Published.IsZero() {
		return false
	}
	return !release.Published.After(p.Now.Add(-p.Cooldown))
}

// EligibleOn is when a release leaves the cooldown; zero when its publication
// date is unknown.
func (p SelectionPolicy) EligibleOn(release Release) time.Time {
	if release.Published.IsZero() {
		return time.Time{}
	}
	return release.Published.Add(p.Cooldown)
}

// Select picks the release to propose from `candidates`, newest first, given
// the advisories that affect the pin in use today.
//
// Two rules, in this order:
//
//  1. A pin with known advisories is moved to a release that fixes all of them
//     and introduces nothing, as soon as one exists: the newest such release
//     that has passed the cooldown, or -- when none has -- the OLDEST that has
//     not, with the cooldown waived. Waiting a week on a published fix is the
//     wrong trade, and of several unaged fixes the oldest has had the longest
//     to be scrutinised.
//  2. Otherwise the newest release past the cooldown that is neither malicious
//     nor carrying an advisory the current pin does not already have. A newer
//     release that fails is skipped for an older one that passes, so one bad
//     release does not block every safe update behind it.
func (p SelectionPolicy) Select(current []Advisory, candidates []Candidate) Selection {
	selection := Selection{Remaining: current}
	if len(current) > 0 {
		if target, waived := p.securityTarget(current, candidates); target != nil {
			selection.Target, selection.Waived = target, waived
			selection.Fixed = current
			selection.Remaining = nil
			return selection
		}
	}
	for index := range candidates {
		candidate := &candidates[index]
		if !p.Aged(candidate.Release) {
			if selection.Held == nil {
				selection.Held = &candidate.Release
			}
			continue
		}
		if reason := RejectionReason(current, candidate.Advisories); reason != "" {
			selection.Rejected = append(selection.Rejected, Rejection{Version: candidate.Version, Reason: reason})
			continue
		}
		selection.Target = candidate
		selection.Fixed = Resolved(current, candidate.Advisories)
		selection.Remaining = Introduced(selection.Fixed, current)
		break
	}
	return selection
}

func (p SelectionPolicy) securityTarget(current []Advisory, candidates []Candidate) (*Candidate, bool) {
	var oldestUnaged *Candidate
	for index := range candidates {
		candidate := &candidates[index]
		if RejectionReason(current, candidate.Advisories) != "" ||
			len(Resolved(current, candidate.Advisories)) != len(current) {
			continue
		}
		if p.Aged(candidate.Release) {
			return candidate, false
		}
		oldestUnaged = candidate
	}
	return oldestUnaged, oldestUnaged != nil
}

// RejectionReason is why a release must not be adopted by a pin currently
// affected by `current`, or empty when it may be.
func RejectionReason(current, proposed []Advisory) string {
	if malicious := slices.DeleteFunc(slices.Clone(proposed), func(advisory Advisory) bool {
		return !advisory.IsMalicious()
	}); len(malicious) > 0 {
		return "known malicious release (" + strings.Join(AdvisoryIDs(malicious), ", ") + ")"
	}
	if introduced := Introduced(current, proposed); len(introduced) > 0 {
		return "would introduce " + strings.Join(AdvisoryIDs(introduced), ", ")
	}
	return ""
}

// NewestFirst orders releases from the highest version down.
func NewestFirst(releases []Release) {
	slices.SortStableFunc(releases, func(left, right Release) int {
		return CompareVersions(right.Version, left.Version)
	})
}
