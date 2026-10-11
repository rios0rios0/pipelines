package commands

import (
	"maps"
	"slices"
	"strings"

	"github.com/rios0rios0/pipelines/global/scripts/tools/dependency-updates/internal/domain/entities"
	"github.com/rios0rios0/pipelines/global/scripts/tools/dependency-updates/internal/domain/repositories"
)

// digestPreview is how much of an untracked digest a report shows.
const digestPreview = 12

// Annotations an untracked pin can be missing.
const (
	missingUpstream = "upstream"
	missingAsset    = "asset"
	missingOSV      = "osv"
)

// BuildTasks turns the manifest, and the actions and images the repository's
// files pin, into one task per dependency, minus the labels `ignores` names.
func BuildTasks(
	workspace repositories.WorkspaceRepository, manifest []entities.ManifestEntry, ignores []string,
) ([]*entities.Task, []entities.Untracked) {
	tasks, untracked := manifestTasks(manifest)
	tasks = append(tasks, actionTasks(workspace)...)
	tasks = append(tasks, imageTasks(workspace)...)
	if len(ignores) > 0 {
		tasks = slices.DeleteFunc(
			tasks,
			func(task *entities.Task) bool { return entities.MatchesAny(task.Label, ignores) },
		)
	}
	return tasks, untracked
}

func manifestTasks(manifest []entities.ManifestEntry) ([]*entities.Task, []entities.Untracked) {
	var (
		tasks     []*entities.Task
		untracked []entities.Untracked
	)
	for index := range manifest {
		entry := &manifest[index]
		// A digest nothing can re-derive is a pin `--apply` can never bump, and
		// it would go on reading as covered: the same slow loss of coverage an
		// unannotated pin is, so it is reported the same way.
		for _, digest := range entry.Digests {
			if digest.Asset == "" {
				untracked = append(untracked, entities.Untracked{
					Name: digest.Var, Current: digest.Value[:digestPreview], Missing: missingAsset,
				})
			}
		}
		switch entry.Kind {
		case entities.KindUnannotated:
			untracked = append(
				untracked,
				entities.Untracked{Name: entry.Name, Current: entry.Current, Missing: missingUpstream},
			)
			continue
		case entities.KindNone:
			continue
		}
		// A binary with no advisory source would read as "no known
		// vulnerabilities" forever. `# osv: none` is the reviewed way to say
		// there is none; silence is not.
		if _, implied := impliedEcosystems()[entry.Kind]; !implied && entry.Advisories == nil {
			untracked = append(
				untracked,
				entities.Untracked{Name: entry.Name, Current: entry.Current, Missing: missingOSV},
			)
		}
		task := &entities.Task{
			Group: entities.GroupManifest, Label: entry.Name, Kind: entry.Kind, Coord: entry.Coord,
			TrackMajor: entry.TrackMajor, Current: entry.Current, Entry: entry,
		}
		if entities.IsTaggedKind(entry.Kind) {
			task.Family, task.HasFamily = entities.TagFamily(entry.Current)
		}
		tasks = append(tasks, task)
	}
	return tasks, untracked
}

func actionTasks(workspace repositories.WorkspaceRepository) []*entities.Task {
	actions := make(map[string]entities.ActionPin)
	for _, path := range workspace.YAMLFiles() {
		entities.ScanActions(workspace.Text(path), actions)
	}
	tasks := make([]*entities.Task, 0, len(actions))
	for _, repository := range slices.Sorted(maps.Keys(actions)) {
		pin := actions[repository]
		task := &entities.Task{
			Group: entities.GroupAction, Label: repository, Kind: entities.KindGitHubRelease, Coord: repository,
			Current: pin.Version, CurrentSHA: pin.SHA,
		}
		task.Family, task.HasFamily = entities.TagFamily(pin.Version)
		tasks = append(tasks, task)
	}
	return tasks
}

func imageTasks(workspace repositories.WorkspaceRepository) []*entities.Task {
	images := make(map[string]string)
	for _, path := range workspace.YAMLFiles() {
		entities.ScanImages(workspace.Text(path), false, images)
	}
	for _, path := range workspace.Dockerfiles() {
		entities.ScanImages(workspace.Text(path), true, images)
	}
	tasks := make([]*entities.Task, 0, len(images))
	for _, reference := range slices.Sorted(maps.Keys(images)) {
		label, _, _ := strings.Cut(reference, "@")
		tasks = append(tasks, &entities.Task{
			Group:   entities.GroupImage,
			Label:   label,
			Kind:    entities.KindImage,
			Coord:   reference,
			Current: images[reference],
		})
	}
	return tasks
}

// InlineFiles are the files an inline copy can live in.
func InlineFiles(workspace repositories.WorkspaceRepository) []string {
	return append(slices.Clone(workspace.YAMLFiles()), workspace.Dockerfiles()...)
}

// FindDrift lists every inline copy that disagrees with the manifest.
func FindDrift(workspace repositories.WorkspaceRepository, manifest []entities.ManifestEntry) []entities.Drift {
	paths := InlineFiles(workspace)
	files := make([]entities.SourceText, 0, len(paths))
	for _, path := range paths {
		files = append(files, entities.SourceText{Path: path, Text: workspace.Text(path)})
	}
	return entities.FindDrift(files, entities.ManifestValues(manifest))
}
