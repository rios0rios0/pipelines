// Package commands holds what the license normalisation does to a BOM.
package commands

import (
	"fmt"

	"github.com/rios0rios0/pipelines/global/scripts/languages/golang/cyclonedx/licenses/internal/domain/entities"
	"github.com/rios0rios0/pipelines/global/scripts/languages/golang/cyclonedx/licenses/internal/domain/repositories"
)

// Result is what a run found and did.
type Result struct {
	// List is the version of the SPDX license list the ids were checked against.
	List string
	// Checked is how many license ids the BOM holds.
	Checked int
	// Fixes are the licenses rewritten. The BOM was written back only when there is one.
	Fixes []entities.Fix
}

// NormalizeLicensesCommand makes every license id of a BOM one the SPDX license list holds.
type NormalizeLicensesCommand struct {
	boms     repositories.BOMRepository
	licenses repositories.LicenseListRepository
}

// NewNormalizeLicensesCommand wires the command to the BOM and to the license list.
func NewNormalizeLicensesCommand(
	boms repositories.BOMRepository, licenses repositories.LicenseListRepository,
) *NormalizeLicensesCommand {
	return &NormalizeLicensesCommand{boms: boms, licenses: licenses}
}

// Execute checks every license id of the BOM against the list and writes the BOM back when it
// rewrote one. A BOM with nothing to rewrite is never written, so it stays byte for byte as the
// generator left it.
func (c *NormalizeLicensesCommand) Execute() (Result, error) {
	list, err := c.licenses.Load()
	if err != nil {
		return Result{}, fmt.Errorf("could not load the SPDX license list: %w", err)
	}
	document, err := c.boms.Read()
	if err != nil {
		return Result{}, fmt.Errorf("could not read the BOM: %w", err)
	}
	normalized, err := entities.NormalizeLicenses(document, list)
	if err != nil {
		return Result{}, err
	}
	result := Result{List: list.Version(), Checked: normalized.Checked, Fixes: normalized.Fixes}
	if len(normalized.Fixes) == 0 {
		return result, nil
	}
	if err = c.boms.Write(normalized.Document); err != nil {
		return Result{}, fmt.Errorf("could not write the BOM: %w", err)
	}
	return result, nil
}
