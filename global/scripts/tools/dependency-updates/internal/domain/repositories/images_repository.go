package repositories

// ImagesRepository answers questions about container registries.
type ImagesRepository interface {
	// Exists is true when the repository named by `reference` holds the
	// manifest its digest names.
	Exists(reference string) (bool, error)
}
