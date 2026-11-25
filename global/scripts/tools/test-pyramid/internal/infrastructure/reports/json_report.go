package reports

import (
	"encoding/json"

	"github.com/rios0rios0/pipelines/global/scripts/tools/test-pyramid/internal/domain/entities"
)

// jsonReport is the report's JSON shape, which other tools read: kept stable, extended only.
type jsonReport struct {
	Target   string      `json:"target"`
	Base     string      `json:"base"`
	Head     string      `json:"head"`
	Blocking bool        `json:"blocking"`
	Verdict  string      `json:"verdict"`
	Suites   []jsonSuite `json:"suites"`
}

type jsonSuite struct {
	Language    string     `json:"language"`
	Verdict     string     `json:"verdict"`
	Mix         string     `json:"mix"`
	Target      jsonCounts `json:"target"`
	PullRequest jsonCounts `json:"pull_request"`
	Findings    []string   `json:"findings"`
}

type jsonCounts struct {
	Unit        int    `json:"unit"`
	Integration int    `json:"integration"`
	Functional  int    `json:"functional"`
	E2E         int    `json:"e2e"`
	Total       int    `json:"total"`
	Shape       string `json:"shape"`
}

// JSON is the judgement as JSON.
func JSON(report entities.Report) ([]byte, error) {
	document := jsonReport{
		Target:   report.Target,
		Base:     report.Base.Commit,
		Head:     report.Head,
		Blocking: report.Blocking,
		Verdict:  outcome(len(report.Worsened()) > 0),
		Suites:   []jsonSuite{},
	}
	for _, suite := range report.Suites {
		verdict := suite.Verdict
		findings := verdict.Findings
		if findings == nil {
			findings = []string{}
		}
		document.Suites = append(document.Suites, jsonSuite{
			Language:    verdict.Language,
			Verdict:     outcome(verdict.Worsened()),
			Mix:         verdict.Mix.String(),
			Target:      countsOf(verdict.Target, verdict.TargetShape()),
			PullRequest: countsOf(verdict.PullRequest, verdict.PullRequestShape()),
			Findings:    findings,
		})
	}
	return json.MarshalIndent(document, "", "  ")
}

func countsOf(counts entities.Counts, shape entities.Shape) jsonCounts {
	return jsonCounts{
		Unit:        counts.Of(entities.TierUnit),
		Integration: counts.Of(entities.TierIntegration),
		Functional:  counts.Of(entities.TierFunctional),
		E2E:         counts.Of(entities.TierE2E),
		Total:       counts.Total(),
		Shape:       string(shape),
	}
}

func outcome(worsened bool) string {
	if worsened {
		return "worsened"
	}
	return "kept"
}
