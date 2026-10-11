package reports

import (
	"encoding/json"

	"github.com/rios0rios0/pipelines/global/scripts/tools/dependency-updates/internal/domain/commands"
	"github.com/rios0rios0/pipelines/global/scripts/tools/dependency-updates/internal/domain/entities"
)

// jsonTask is a task as the JSON report records it.
type jsonTask struct {
	Group    string `json:"group"`
	Label    string `json:"label"`
	Kind     string `json:"kind"`
	Coord    string `json:"coord"`
	Current  string `json:"current"`
	Latest   string `json:"latest"`
	Proposed string `json:"proposed,omitempty"`
	Outdated bool   `json:"outdated"`
	Error    string `json:"error,omitempty"`
	Refused  string `json:"refused,omitempty"`
	Applied  bool   `json:"applied,omitempty"`
}

type jsonAdvisory struct {
	Pin       string   `json:"pin"`
	Version   string   `json:"version"`
	ID        string   `json:"id"`
	Aliases   []string `json:"aliases,omitempty"`
	Severity  string   `json:"severity"`
	Summary   string   `json:"summary,omitempty"`
	FixedBy   string   `json:"fixed_by,omitempty"`
	Accepted  bool     `json:"accepted,omitempty"`
	Malicious bool     `json:"malicious,omitempty"`
}

type jsonLabelled struct {
	Label string `json:"label"`
	Error string `json:"error"`
}

type jsonDrift struct {
	Name     string `json:"name"`
	File     string `json:"file"`
	Inline   string `json:"inline"`
	Manifest string `json:"manifest"`
}

type jsonUntracked struct {
	Kind    string `json:"kind"`
	Missing string `json:"missing"`
	Name    string `json:"name"`
	Current string `json:"current"`
}

type jsonCopy struct {
	Var     string `json:"var"`
	File    string `json:"file"`
	From    string `json:"from"`
	To      string `json:"to"`
	Drifted bool   `json:"drifted"`
}

// PullRequestRecord is what the JSON report records of a pull request.
type PullRequestRecord struct {
	Title        string     `json:"title"`
	Fingerprint  string     `json:"fingerprint"`
	Changelog    string     `json:"changelog"`
	ChangedFiles []string   `json:"changed_files"`
	Applied      []jsonTask `json:"applied"`
	Refused      []jsonTask `json:"refused"`
	InlineCopies []jsonCopy `json:"inline_copies"`
}

type jsonReport struct {
	Checked         int                `json:"checked"`
	Outdated        []jsonTask         `json:"outdated"`
	Errors          []jsonLabelled     `json:"errors"`
	DriftedCopies   []jsonDrift        `json:"drifted_copies"`
	UnannotatedPins []jsonUntracked    `json:"unannotated_pins"`
	Vulnerabilities []jsonAdvisory     `json:"vulnerabilities"`
	AdvisoryError   string             `json:"advisory_error,omitempty"`
	PullRequest     *PullRequestRecord `json:"pull_request,omitempty"`
}

func toJSONTask(task *entities.Task) jsonTask {
	return jsonTask{
		Group: string(task.Group), Label: task.Label, Kind: task.Kind, Coord: task.Coord, Current: task.Current,
		Latest: task.Latest, Proposed: task.Proposed(), Outdated: task.Outdated, Error: task.Error,
		Refused: task.Refused, Applied: task.Applied,
	}
}

func toJSONTasks(tasks []*entities.Task) []jsonTask {
	converted := make([]jsonTask, 0, len(tasks))
	for _, task := range tasks {
		converted = append(converted, toJSONTask(task))
	}
	return converted
}

// NewPullRequestRecord records a pull request for the JSON report.
func NewPullRequestRecord(
	apply commands.ApplyResult, title, fingerprint, changelog string, changed []string,
) *PullRequestRecord {
	record := &PullRequestRecord{
		Title: title, Fingerprint: fingerprint, Changelog: changelog, ChangedFiles: changed,
		Applied: toJSONTasks(apply.Applied), Refused: toJSONTasks(apply.Refused), InlineCopies: []jsonCopy{},
	}
	for _, fix := range apply.Fixes {
		record.InlineCopies = append(
			record.InlineCopies,
			jsonCopy{Var: fix.Var, File: fix.File, From: fix.From, To: fix.To, Drifted: fix.Drifted},
		)
	}
	return record
}

// JSON is the machine-readable report.
func JSON(check commands.CheckResult, pullRequest *PullRequestRecord) ([]byte, error) {
	report := jsonReport{
		Checked: len(check.Tasks), Outdated: toJSONTasks(check.Outdated()), Errors: []jsonLabelled{},
		DriftedCopies: []jsonDrift{}, UnannotatedPins: []jsonUntracked{}, Vulnerabilities: []jsonAdvisory{},
		AdvisoryError: check.AdvisoryError, PullRequest: pullRequest,
	}
	for _, task := range check.Failed() {
		report.Errors = append(report.Errors, jsonLabelled{Label: task.Label, Error: task.Error})
	}
	for _, row := range check.Drift {
		report.DriftedCopies = append(report.DriftedCopies, jsonDrift(row))
	}
	for _, row := range check.Untracked {
		report.UnannotatedPins = append(report.UnannotatedPins, jsonUntracked{
			Kind: entities.KindUnannotated, Missing: row.Missing, Name: row.Name, Current: row.Current,
		})
	}
	for _, task := range SortedTasks(check.Tasks) {
		report.Vulnerabilities = append(report.Vulnerabilities, advisoriesOf(task)...)
	}
	return json.MarshalIndent(report, "", "  ")
}

func advisoriesOf(task *entities.Task) []jsonAdvisory {
	var rows []jsonAdvisory
	record := func(advisory entities.Advisory, accepted bool) {
		row := jsonAdvisory{
			Pin: task.Label, Version: task.Security.Version, ID: advisory.ID, Aliases: advisory.Aliases,
			Severity: advisory.DisplaySeverity(), Summary: advisory.Summary, Accepted: accepted,
			Malicious: advisory.IsMalicious(),
		}
		for _, fixed := range task.Selection.Fixed {
			if fixed.SameIssue(advisory) {
				row.FixedBy = task.Proposed()
			}
		}
		rows = append(rows, row)
	}
	for _, advisory := range task.Security.Current {
		record(advisory, false)
	}
	for _, advisory := range task.Security.Accepted {
		record(advisory, true)
	}
	return rows
}
