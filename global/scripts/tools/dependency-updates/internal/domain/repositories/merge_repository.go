package repositories

// MergeRepository merges a vendored file's local adjustments onto a new
// upstream release.
type MergeRepository interface {
	// Merge applies the change from `base` to `theirs` onto `ours`. Conflicts
	// is the number of regions it could not reconcile.
	Merge(ours, base, theirs string) (merged string, conflicts int, err error)
}
