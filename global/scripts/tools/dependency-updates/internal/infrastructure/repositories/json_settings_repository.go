package repositories

import (
	"encoding/json"
	"fmt"
	"io"
	"regexp"
	"time"

	"github.com/rios0rios0/pipelines/global/scripts/tools/dependency-updates/internal/domain/entities"
	"github.com/rios0rios0/pipelines/global/scripts/tools/dependency-updates/internal/domain/repositories"
)

// SettingsFile is the repository's settings, at its root.
const SettingsFile = ".dependency-updates.json"

var acceptanceDate = regexp.MustCompile(`^\d{4}-\d{2}-\d{2}$`)

// JSONSettingsRepository reads `.dependency-updates.json` through the
// workspace:
//
//	{
//	  "ignore":   ["alpine:edge"],
//	  "cooldown": {"days": 7, "exempt": ["rios0rios0/*"]},
//	  "vulnerabilities": {
//	    "accept": [{"id": "GHSA-...", "reason": "...", "until": "2026-12-31"}]
//	  }
//	}
//
// A file that cannot be read applies NOTHING from it, which is the safe
// direction for every field: no pin ignored, the default cooldown, no
// advisory accepted. An acceptance without a reason or an expiry date is
// refused the same way -- accepting a known vulnerability forever, or without
// saying why, is not a decision review can check.
type JSONSettingsRepository struct {
	workspace repositories.WorkspaceRepository
	warnings  io.Writer
}

// NewJSONSettingsRepository builds the reader; problems are reported on
// `warnings`.
func NewJSONSettingsRepository(workspace repositories.WorkspaceRepository, warnings io.Writer) *JSONSettingsRepository {
	return &JSONSettingsRepository{workspace: workspace, warnings: warnings}
}

type settingsDocument struct {
	Ignore   []string `json:"ignore"`
	Cooldown *struct {
		Days   *int     `json:"days"`
		Exempt []string `json:"exempt"`
	} `json:"cooldown"`
	Vulnerabilities struct {
		Accept []struct {
			ID     string `json:"id"`
			Reason string `json:"reason"`
			Until  string `json:"until"`
		} `json:"accept"`
	} `json:"vulnerabilities"`
}

// Load reads the settings; a repository without the file has none.
func (r *JSONSettingsRepository) Load() (entities.Settings, error) {
	if !r.workspace.IsFile(SettingsFile) {
		return entities.Settings{}, nil
	}
	var document settingsDocument
	if err := json.Unmarshal([]byte(r.workspace.Text(SettingsFile)), &document); err != nil {
		r.warnf("WARNING: could not read %s (%s); applying nothing from it\n", SettingsFile, err)
		return entities.Settings{}, nil
	}
	settings := entities.Settings{Ignore: document.Ignore}
	if document.Cooldown != nil {
		settings.CooldownExempt = document.Cooldown.Exempt
		if days := document.Cooldown.Days; days != nil && *days >= 0 {
			settings.Cooldown, settings.HasCooldown = time.Duration(*days)*entities.Day, true
		}
	}
	for _, acceptance := range document.Vulnerabilities.Accept {
		if acceptance.ID == "" || acceptance.Reason == "" || !acceptanceDate.MatchString(acceptance.Until) {
			r.warnf("WARNING: %s: an acceptance needs an id, a reason and an `until` date (YYYY-MM-DD); "+
				"ignoring %q\n", SettingsFile, acceptance.ID)
			continue
		}
		settings.Acceptances = append(settings.Acceptances, entities.Acceptance{
			ID: acceptance.ID, Reason: acceptance.Reason, Until: acceptance.Until,
		})
	}
	return settings, nil
}

func (r *JSONSettingsRepository) warnf(format string, arguments ...any) {
	if r.warnings != nil {
		_, _ = fmt.Fprintf(r.warnings, format, arguments...)
	}
}
