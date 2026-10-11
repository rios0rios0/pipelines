package repositories

import "github.com/rios0rios0/pipelines/global/scripts/tools/dependency-updates/internal/domain/entities"

// SettingsRepository reads `.dependency-updates.json`.
type SettingsRepository interface {
	Load() (entities.Settings, error)
}
