package commands

import (
	"fmt"

	"github.com/rios0rios0/pipelines/global/scripts/tools/dependency-updates/internal/domain/entities"
	"github.com/rios0rios0/pipelines/global/scripts/tools/dependency-updates/internal/domain/repositories"
)

// Statuses one committed digest can have.
const (
	AssetOK       = "OK"
	AssetMissing  = "MISSING"
	AssetMismatch = "MISMATCH"
	AssetError    = "ERROR"
)

// AssetCheck is one committed digest checked against what upstream serves.
type AssetCheck struct {
	Status string
	Name   string
	Detail string
}

// VerifyAssetsCommand checks every `# asset:` template against the digest
// committed beside it: for editing the annotations rather than for CI, since it
// asks upstream about every pin, bumped or not.
type VerifyAssetsCommand struct {
	artifacts repositories.ArtifactsRepository
}

// NewVerifyAssetsCommand builds the check.
func NewVerifyAssetsCommand(artifacts repositories.ArtifactsRepository) *VerifyAssetsCommand {
	return &VerifyAssetsCommand{artifacts: artifacts}
}

// Execute checks every digest of every entry at the version each is pinned at.
func (c *VerifyAssetsCommand) Execute(manifest []entities.ManifestEntry) []AssetCheck {
	var checks []AssetCheck
	for _, entry := range manifest {
		checks = append(checks, c.Entry(entry, entry.Current)...)
	}
	return checks
}

// Entry checks one entry's digests as committed for `version`.
func (c *VerifyAssetsCommand) Entry(entry entities.ManifestEntry, version string) []AssetCheck {
	if len(entry.Digests) == 0 {
		return nil
	}
	var checks []AssetCheck
	manifestText, problem := c.checksumManifest(entry, version)
	if problem != "" {
		checks = append(checks, AssetCheck{Status: AssetError, Name: entry.Name, Detail: "checksums: " + problem})
	}
	for _, digest := range entry.Digests {
		status, detail := c.digest(digest, version, manifestText)
		checks = append(checks, AssetCheck{Status: status, Name: digest.Var, Detail: detail})
	}
	return checks
}

func (c *VerifyAssetsCommand) checksumManifest(entry entities.ManifestEntry, version string) (*string, string) {
	if entry.Checksums == "" {
		return nil, ""
	}
	text, err := c.artifacts.Text(entities.Render(entry.Checksums, version))
	if err != nil {
		return nil, err.Error()
	}
	return &text, ""
}

func (c *VerifyAssetsCommand) digest(digest entities.Digest, version string, manifestText *string) (string, string) {
	if digest.Asset == "" {
		return AssetMissing, "no `# asset:` annotation"
	}
	url := entities.Render(digest.Asset, version)
	value, source, err := c.artifacts.AssetDigest(url)
	switch {
	case repositories.IsNotFound(err):
		return AssetMissing, err.Error()
	case err != nil:
		return AssetError, err.Error()
	case value != digest.Value:
		return AssetMismatch, fmt.Sprintf("%s is %s, committed %s", url, value, digest.Value)
	case manifestText == nil:
		return AssetOK, source
	}
	if published := entities.PublishedChecksum(*manifestText, entities.AssetName(url)); published != value {
		return AssetMismatch, "the checksum manifest says " + published
	}
	return AssetOK, source + ", matching the checksum manifest"
}
