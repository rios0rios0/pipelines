package repositories

import "time"

// HistoryRepository answers questions about the scanned repository's history.
type HistoryRepository interface {
	// HeadCommitTime is when the commit the tree was built from was made.
	HeadCommitTime() (time.Time, error)
}
