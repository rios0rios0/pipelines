package repositories

import (
	"encoding/json"
	"slices"
	"sync"

	"github.com/rios0rios0/pipelines/global/scripts/tools/dependency-updates/internal/domain/entities"
	"github.com/rios0rios0/pipelines/global/scripts/tools/dependency-updates/internal/domain/repositories"
)

const (
	osvAPI = "https://api.osv.dev/v1"
	// osvBatchSize is how many queries one querybatch call carries.
	osvBatchSize = 1000
	// osvMaxPages bounds how far one package's advisory listing is followed.
	osvMaxPages = 20
)

// osvVulnerability is one record in OSV's schema.
type osvVulnerability struct {
	ID        string   `json:"id"`
	Aliases   []string `json:"aliases"`
	Summary   string   `json:"summary"`
	Details   string   `json:"details"`
	Withdrawn string   `json:"withdrawn"`
	Severity  []struct {
		Type  string `json:"type"`
		Score string `json:"score"`
	} `json:"severity"`
	DatabaseSpecific struct {
		Severity string   `json:"severity"`
		CWEIDs   []string `json:"cwe_ids"`
	} `json:"database_specific"`
	Affected []struct {
		Package struct {
			Ecosystem string `json:"ecosystem"`
			Name      string `json:"name"`
		} `json:"package"`
		Versions         []string `json:"versions"`
		DatabaseSpecific struct {
			LastKnownAffected string `json:"last_known_affected_version_range"`
		} `json:"database_specific"`
		Ranges []struct {
			Type   string `json:"type"`
			Events []struct {
				Introduced   string `json:"introduced"`
				Fixed        string `json:"fixed"`
				LastAffected string `json:"last_affected"`
			} `json:"events"`
		} `json:"ranges"`
	} `json:"affected"`
}

// toAdvisory maps an OSV record onto the domain.
func (v osvVulnerability) toAdvisory() entities.Advisory {
	advisory := entities.Advisory{
		ID: v.ID, Aliases: v.Aliases, Summary: v.Summary, Severity: v.DatabaseSpecific.Severity,
		CWEs: v.DatabaseSpecific.CWEIDs, Withdrawn: v.Withdrawn != "",
	}
	if advisory.Summary == "" {
		advisory.Summary = firstLine(v.Details)
	}
	for _, affected := range v.Affected {
		pkg := entities.AffectedPackage{
			Package:           entities.Package{Ecosystem: affected.Package.Ecosystem, Name: affected.Package.Name},
			Versions:          affected.Versions,
			LastKnownAffected: affected.DatabaseSpecific.LastKnownAffected,
		}
		for _, affectedRange := range affected.Ranges {
			converted := entities.AffectedRange{Type: affectedRange.Type}
			for _, event := range affectedRange.Events {
				converted.Events = append(converted.Events, entities.RangeEvent{
					Introduced: event.Introduced, Fixed: event.Fixed, LastAffected: event.LastAffected,
				})
			}
			pkg.Ranges = append(pkg.Ranges, converted)
		}
		advisory.Affected = append(advisory.Affected, pkg)
	}
	return advisory
}

func firstLine(text string) string {
	for index, character := range text {
		if character == '\n' {
			return text[:index]
		}
	}
	return text
}

// OSVAdvisoriesRepository asks OSV.dev, which aggregates GitHub's reviewed and
// malware advisories, the OpenSSF malicious-packages feed, the Go
// vulnerability database, PyPA and RubySec.
type OSVAdvisoriesRepository struct {
	transport Transport
	api       string
	records   sync.Map
}

// NewOSVAdvisoriesRepository builds the live repository.
func NewOSVAdvisoriesRepository(transport Transport) *OSVAdvisoriesRepository {
	return NewOSVAdvisoriesRepositoryAt(transport, osvAPI)
}

// NewOSVAdvisoriesRepositoryAt builds the repository against another OSV API
// root -- a mirror, or a test server.
func NewOSVAdvisoriesRepositoryAt(transport Transport, api string) *OSVAdvisoriesRepository {
	return &OSVAdvisoriesRepository{transport: transport, api: api}
}

type osvPackage struct {
	Name      string `json:"name"`
	Ecosystem string `json:"ecosystem"`
}

type osvQuery struct {
	Package   osvPackage `json:"package"`
	Version   string     `json:"version,omitempty"`
	PageToken string     `json:"page_token,omitempty"`
}

// FindAll answers every query. GitHub Actions are asked about by package and
// evaluated here, because OSV does not order action versions; everything else
// is asked about by version, evaluated by OSV.
func (r *OSVAdvisoriesRepository) FindAll(
	queries []entities.AdvisoryQuery,
) (map[entities.AdvisoryQuery][]entities.Advisory, error) {
	found := make(map[entities.AdvisoryQuery][]entities.Advisory, len(queries))
	var versioned []entities.AdvisoryQuery
	byPackage := make(map[entities.Package][]entities.AdvisoryQuery)
	for _, query := range dedupe(queries) {
		if query.Package.Ecosystem == entities.EcosystemGitHubActions {
			byPackage[query.Package] = append(byPackage[query.Package], query)
		} else {
			versioned = append(versioned, query)
		}
	}
	for pkg, packageQueries := range byPackage {
		advisories, err := r.packageAdvisories(pkg)
		if err != nil {
			return nil, err
		}
		for _, query := range packageQueries {
			found[query] = affecting(advisories, query)
		}
	}
	for start := 0; start < len(versioned); start += osvBatchSize {
		if err := r.batch(versioned[start:min(start+osvBatchSize, len(versioned))], found); err != nil {
			return nil, err
		}
	}
	return found, nil
}

func dedupe(queries []entities.AdvisoryQuery) []entities.AdvisoryQuery {
	unique := slices.Clone(queries)
	slices.SortFunc(unique, func(left, right entities.AdvisoryQuery) int {
		return compareStrings(left.Package.Ecosystem+"\x00"+left.Package.Name+"\x00"+left.Version,
			right.Package.Ecosystem+"\x00"+right.Package.Name+"\x00"+right.Version)
	})
	return slices.Compact(unique)
}

func compareStrings(left, right string) int {
	switch {
	case left < right:
		return -1
	case left > right:
		return 1
	default:
		return 0
	}
}

func affecting(advisories []entities.Advisory, query entities.AdvisoryQuery) []entities.Advisory {
	var hits []entities.Advisory
	for _, advisory := range advisories {
		if advisory.Affects(query.Package, query.Version) {
			hits = append(hits, advisory)
		}
	}
	return hits
}

// packageAdvisories is every advisory OSV holds for a package, page by page.
func (r *OSVAdvisoriesRepository) packageAdvisories(pkg entities.Package) ([]entities.Advisory, error) {
	var (
		advisories []entities.Advisory
		token      string
	)
	for range osvMaxPages {
		body, _ := json.Marshal(
			osvQuery{Package: osvPackage{Name: pkg.Name, Ecosystem: pkg.Ecosystem}, PageToken: token},
		)
		content, err := r.transport.Post(r.api+"/query", body)
		if err != nil {
			return nil, err
		}
		var answer struct {
			Vulns         []osvVulnerability `json:"vulns"`
			NextPageToken string             `json:"next_page_token"`
		}
		if decodeErr := json.Unmarshal(content, &answer); decodeErr != nil {
			return nil, repositories.NewLookupError("%s/query -> not JSON: %s", r.api, decodeErr)
		}
		for _, vulnerability := range answer.Vulns {
			advisories = append(advisories, vulnerability.toAdvisory())
		}
		if answer.NextPageToken == "" {
			return advisories, nil
		}
		token = answer.NextPageToken
	}
	return nil, repositories.NewLookupError(
		"%s/query -> more than %d pages of advisories for %s",
		r.api,
		osvMaxPages,
		pkg.Name,
	)
}

// batch asks about many versions at once; OSV answers with IDs, and each
// distinct record is then read once.
func (r *OSVAdvisoriesRepository) batch(
	queries []entities.AdvisoryQuery,
	found map[entities.AdvisoryQuery][]entities.Advisory,
) error {
	request := struct {
		Queries []osvQuery `json:"queries"`
	}{}
	for _, query := range queries {
		request.Queries = append(request.Queries, osvQuery{
			Package: osvPackage{Name: query.Package.Name, Ecosystem: query.Package.Ecosystem}, Version: query.Version,
		})
	}
	body, _ := json.Marshal(request)
	content, err := r.transport.Post(r.api+"/querybatch", body)
	if err != nil {
		return err
	}
	var answer struct {
		Results []struct {
			Vulns []struct {
				ID string `json:"id"`
			} `json:"vulns"`
			NextPageToken string `json:"next_page_token"`
		} `json:"results"`
	}
	if decodeErr := json.Unmarshal(content, &answer); decodeErr != nil || len(answer.Results) != len(queries) {
		return repositories.NewLookupError(
			"%s/querybatch -> an answer that does not match the %d queries asked",
			r.api,
			len(queries),
		)
	}
	for index, result := range answer.Results {
		if result.NextPageToken != "" {
			// More advisories than one page: refuse to call the version
			// assessed on a partial list.
			return repositories.NewLookupError("%s/querybatch -> %s %s has more advisories than one answer holds",
				r.api, queries[index].Package.Name, queries[index].Version)
		}
		for _, reference := range result.Vulns {
			advisory, recordErr := r.record(reference.ID)
			if recordErr != nil {
				return recordErr
			}
			found[queries[index]] = append(found[queries[index]], advisory)
		}
	}
	return nil
}

func (r *OSVAdvisoriesRepository) record(identifier string) (entities.Advisory, error) {
	if cached, seen := r.records.Load(identifier); seen {
		advisory, _ := cached.(entities.Advisory)
		return advisory, nil
	}
	content, err := r.transport.Get(r.api+"/vulns/"+identifier, nil, MaxDocumentBytes)
	if err != nil {
		return entities.Advisory{}, err
	}
	var vulnerability osvVulnerability
	if decodeErr := json.Unmarshal(content, &vulnerability); decodeErr != nil {
		return entities.Advisory{}, repositories.NewLookupError(
			"%s/vulns/%s -> not JSON: %s", r.api, identifier, decodeErr)
	}
	advisory := vulnerability.toAdvisory()
	r.records.Store(identifier, advisory)
	return advisory, nil
}

// FixtureAdvisoriesRepository answers from a fixture's
// `osv:<ecosystem>:<package>` entries -- OSV records -- evaluated here for
// every ecosystem. `osv:*` answers for any package without its own entry, and
// is the explicit way a test that is not about advisories says so; without it
// a package with no entry is a failed lookup, never "no advisories".
type FixtureAdvisoriesRepository struct {
	fixture Fixture
}

// NewFixtureAdvisoriesRepository builds the offline repository.
func NewFixtureAdvisoriesRepository(fixture Fixture) *FixtureAdvisoriesRepository {
	return &FixtureAdvisoriesRepository{fixture: fixture}
}

// FindAll evaluates each query against its package's fixture records.
func (r *FixtureAdvisoriesRepository) FindAll(
	queries []entities.AdvisoryQuery,
) (map[entities.AdvisoryQuery][]entities.Advisory, error) {
	found := make(map[entities.AdvisoryQuery][]entities.Advisory, len(queries))
	for _, query := range queries {
		key := "osv:" + query.Package.Ecosystem + ":" + query.Package.Name
		raw, err := r.fixture.Answer(key)
		if err != nil && !repositories.IsNotFound(err) {
			raw, err = r.fixture.Answer("osv:*")
		}
		if err != nil {
			return nil, repositories.NewLookupError("no fixture entry for %s", key)
		}
		var records []osvVulnerability
		if decodeErr := json.Unmarshal(raw, &records); decodeErr != nil {
			return nil, repositories.NewLookupError("fixture %s is not a list of OSV records", key)
		}
		advisories := make([]entities.Advisory, 0, len(records))
		for _, record := range records {
			advisories = append(advisories, record.toAdvisory())
		}
		found[query] = affecting(advisories, query)
	}
	return found, nil
}
