package repositories

import "github.com/rios0rios0/pipelines/global/scripts/tools/dependency-updates/internal/domain/entities"

// ImageScannerRepository finds the known vulnerabilities inside a container
// image: its OS packages and the artifacts it ships.
type ImageScannerRepository interface {
	// Scan scans the image a digest-pinned reference names.
	Scan(reference string) (entities.ImageScan, error)
}
