package repositories

import (
	"errors"
	"fmt"
)

// LookupError is an upstream that could not be consulted. It is never treated
// as "up to date": a rate-limited API would otherwise turn the whole check into
// a green light that inspected nothing, which is worse than not running it.
type LookupError struct {
	Message string
	// NotFound marks a definite answer that what was asked for does not
	// exist. Kept apart from a failed lookup because the two call for
	// different things: a release asset answering 404 is usually an upstream
	// renaming its assets, which the installer has to follow by hand, while a
	// timeout says nothing at all and must never be read as "absent".
	NotFound bool
}

func (e *LookupError) Error() string {
	return e.Message
}

// NewLookupError is an upstream that could not be consulted.
func NewLookupError(format string, arguments ...any) error {
	return &LookupError{Message: fmt.Sprintf(format, arguments...)}
}

// NewNotFoundError is an upstream answering that something does not exist.
func NewNotFoundError(format string, arguments ...any) error {
	return &LookupError{Message: fmt.Sprintf(format, arguments...), NotFound: true}
}

// IsNotFound is true for a definite "does not exist".
func IsNotFound(err error) bool {
	var lookup *LookupError
	return errors.As(err, &lookup) && lookup.NotFound
}

// IsLookupError is true for any upstream failure, a definite 404 included.
func IsLookupError(err error) bool {
	var lookup *LookupError
	return errors.As(err, &lookup)
}
