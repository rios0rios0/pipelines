package commands_test

import (
	"errors"
	"maps"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/rios0rios0/pipelines/global/scripts/tools/test-pyramid/internal/domain/commands"
	"github.com/rios0rios0/pipelines/global/scripts/tools/test-pyramid/internal/domain/entities"
	"github.com/rios0rios0/pipelines/global/scripts/tools/test-pyramid/internal/test/doubles"
)

const (
	baseCommit = "base0000"
	headCommit = "head0000"
	unitTest   = "func TestA(t *testing.T) {}\n"
	e2eTest    = "//go:build e2e\n\npackage e2e\n\nfunc TestFlow(t *testing.T) {}\nfunc TestCheckout(t *testing.T) {}\n"
)

// outcome is which listener the command called, and with what.
type outcome struct {
	called string
	report entities.Report
	err    error
}

func execute(
	trees *doubles.InMemoryTreesRepository,
	revisions *doubles.StubRevisionsRepository,
	request entities.Request,
) outcome {
	var result outcome
	commands.NewJudgeTestPyramidCommand(revisions, trees, entities.Profiles()).Execute(request,
		commands.JudgeTestPyramidCommandListeners{
			OnKept:     func(report entities.Report) { result = outcome{called: "OnKept", report: report} },
			OnWorsened: func(report entities.Report) { result = outcome{called: "OnWorsened", report: report} },
			OnError:    func(err error) { result = outcome{called: "OnError", err: err} },
		})
	return result
}

// unitSuite is a tree of ten Go unit tests and, merged into it, the files given.
func unitSuite(files map[string]string) map[string]string {
	tree := map[string]string{}
	for _, name := range []string{"a", "b", "c", "d", "e", "f", "g", "h", "i", "j"} {
		tree["pkg/"+name+"_test.go"] = unitTest
	}
	maps.Copy(tree, files)
	return tree
}

func goRequest() entities.Request {
	return entities.Request{Target: "main", Languages: []string{"go"}}
}

func TestJudgeTestPyramidCommand(t *testing.T) {
	t.Parallel()

	t.Run("should call OnKept when the pull request adds unit tests", func(t *testing.T) {
		t.Parallel()
		// given
		trees := doubles.NewInMemoryTreesRepository(map[string]map[string]string{
			baseCommit: unitSuite(nil),
			headCommit: unitSuite(map[string]string{"pkg/k_test.go": unitTest}),
		})

		// when
		result := execute(trees, doubles.NewStubRevisionsRepository(headCommit, baseCommit), goRequest())

		// then
		require.Equal(t, "OnKept", result.called, result.err)
		require.Len(t, result.report.Suites, 1)
		assert.Equal(t, 10, result.report.Suites[0].Verdict.Target.Total())
		assert.Equal(t, 11, result.report.Suites[0].Verdict.PullRequest.Total())
		assert.False(t, result.report.Blocking)
	})

	t.Run("should call OnWorsened when the pull request adds e2e tests past the reference mix", func(t *testing.T) {
		t.Parallel()
		// given
		trees := doubles.NewInMemoryTreesRepository(map[string]map[string]string{
			baseCommit: unitSuite(nil),
			headCommit: unitSuite(map[string]string{"e2e/flow_test.go": e2eTest}),
		})

		// when
		result := execute(trees, doubles.NewStubRevisionsRepository(headCommit, baseCommit), goRequest())

		// then
		require.Equal(t, "OnWorsened", result.called, result.err)
		assert.Equal(t, []string{"go"}, result.report.Worsened())
	})

	t.Run(
		"should call OnWorsened under the target branch's policy, not the one the pull request brings",
		func(t *testing.T) {
			t.Parallel()
			// given
			trees := doubles.NewInMemoryTreesRepository(map[string]map[string]string{
				baseCommit: unitSuite(map[string]string{".test-pyramid": "blocking true\n"}),
				headCommit: unitSuite(map[string]string{
					".test-pyramid":    "blocking false\nunit ^e2e/\n",
					"e2e/flow_test.go": e2eTest,
				}),
			})

			// when
			result := execute(trees, doubles.NewStubRevisionsRepository(headCommit, baseCommit), goRequest())

			// then
			require.Equal(t, "OnWorsened", result.called, result.err)
			assert.True(t, result.report.Blocking)
			assert.True(t, result.report.PolicyFound)
			assert.True(t, result.report.PolicyChanged)
		},
	)

	t.Run("should call OnWorsened as blocking when the request insists, whatever the policy", func(t *testing.T) {
		t.Parallel()
		// given
		trees := doubles.NewInMemoryTreesRepository(map[string]map[string]string{
			baseCommit: unitSuite(nil),
			headCommit: unitSuite(map[string]string{"e2e/flow_test.go": e2eTest}),
		})
		request := goRequest()
		request.ForceBlocking = true

		// when
		result := execute(trees, doubles.NewStubRevisionsRepository(headCommit, baseCommit), request)

		// then
		require.Equal(t, "OnWorsened", result.called, result.err)
		assert.True(t, result.report.Blocking)
		assert.False(t, result.report.PolicyFound)
	})

	t.Run("should call OnKept when the target branch's rules classify the new tests lower", func(t *testing.T) {
		t.Parallel()
		// given
		trees := doubles.NewInMemoryTreesRepository(map[string]map[string]string{
			baseCommit: unitSuite(map[string]string{".test-pyramid": "unit ^e2e/\n"}),
			headCommit: unitSuite(map[string]string{".test-pyramid": "unit ^e2e/\n", "e2e/flow_test.go": e2eTest}),
		})

		// when
		result := execute(trees, doubles.NewStubRevisionsRepository(headCommit, baseCommit), goRequest())

		// then
		require.Equal(t, "OnKept", result.called, result.err)
		assert.False(t, result.report.PolicyChanged)
	})

	t.Run("should call OnKept judging the languages the policy names instead of the request's", func(t *testing.T) {
		t.Parallel()
		// given
		tree := map[string]string{".test-pyramid": "languages javascript\n", "src/a.test.ts": "it('adds', () => {});\n"}
		trees := doubles.NewInMemoryTreesRepository(map[string]map[string]string{baseCommit: tree, headCommit: tree})

		// when
		result := execute(trees, doubles.NewStubRevisionsRepository(headCommit, baseCommit), goRequest())

		// then
		require.Equal(t, "OnKept", result.called, result.err)
		require.Len(t, result.report.Suites, 1)
		assert.Equal(t, "javascript", result.report.Suites[0].Verdict.Language)
	})

	t.Run("should call OnKept comparing with the commit the request names", func(t *testing.T) {
		t.Parallel()
		// given
		trees := doubles.NewInMemoryTreesRepository(map[string]map[string]string{
			"older000": unitSuite(nil),
			headCommit: unitSuite(nil),
		})
		revisions := doubles.NewStubRevisionsRepository(headCommit, baseCommit).WithCommit("v1.0.0", "older000")
		request := goRequest()
		request.Base = "v1.0.0"

		// when
		result := execute(trees, revisions, request)

		// then
		require.Equal(t, "OnKept", result.called, result.err)
		assert.Equal(t, "older000", result.report.Base.Commit)
	})

	t.Run("should call OnError when the target branch's .test-pyramid is invalid", func(t *testing.T) {
		t.Parallel()
		// given
		trees := doubles.NewInMemoryTreesRepository(map[string]map[string]string{
			baseCommit: {".test-pyramid": "blocking maybe\n"},
			headCommit: {},
		})

		// when
		result := execute(trees, doubles.NewStubRevisionsRepository(headCommit, baseCommit), goRequest())

		// then
		require.Equal(t, "OnError", result.called)
		require.ErrorContains(t, result.err, "the .test-pyramid of the target branch is invalid")
		assert.ErrorContains(t, result.err, "the one that fixes it included: merge that fix past this check")
	})

	t.Run("should call OnError when the pull request's .test-pyramid is invalid", func(t *testing.T) {
		t.Parallel()
		// given
		trees := doubles.NewInMemoryTreesRepository(map[string]map[string]string{
			baseCommit: {},
			headCommit: {".test-pyramid": "mix 90/20/0\n"},
		})

		// when
		result := execute(trees, doubles.NewStubRevisionsRepository(headCommit, baseCommit), goRequest())

		// then
		require.Equal(t, "OnError", result.called)
		assert.ErrorContains(t, result.err, "the .test-pyramid of this pull request is invalid")
	})

	t.Run("should call OnError when no suite is named", func(t *testing.T) {
		t.Parallel()
		// given
		trees := doubles.NewInMemoryTreesRepository(map[string]map[string]string{baseCommit: {}, headCommit: {}})

		// when
		result := execute(
			trees,
			doubles.NewStubRevisionsRepository(headCommit, baseCommit),
			entities.Request{Target: "main"},
		)

		// then
		require.Equal(t, "OnError", result.called)
		assert.ErrorContains(t, result.err, "no suite to judge")
	})

	t.Run("should call OnError when a language has no profile", func(t *testing.T) {
		t.Parallel()
		// given
		trees := doubles.NewInMemoryTreesRepository(map[string]map[string]string{baseCommit: {}, headCommit: {}})
		request := entities.Request{Target: "main", Languages: []string{"cobol"}}

		// when
		result := execute(trees, doubles.NewStubRevisionsRepository(headCommit, baseCommit), request)

		// then
		require.Equal(t, "OnError", result.called)
		assert.ErrorContains(
			t,
			result.err,
			`no test-pyramid profile for "cobol" (known: dart, dotnet, go, java, javascript, php, python, ruby, terraform)`,
		)
	})

	t.Run("should call OnError when the commits cannot be resolved", func(t *testing.T) {
		t.Parallel()
		// given
		trees := doubles.NewInMemoryTreesRepository(map[string]map[string]string{})
		revisions := doubles.NewStubRevisionsRepository(headCommit, baseCommit).WithError(errors.New("fetch refused"))

		// when
		result := execute(trees, revisions, goRequest())

		// then
		require.Equal(t, "OnError", result.called)
		assert.ErrorContains(t, result.err, "fetch refused")
	})

	t.Run("should call OnError when a tree cannot be read", func(t *testing.T) {
		t.Parallel()
		// given
		trees := doubles.NewInMemoryTreesRepository(map[string]map[string]string{baseCommit: {}, headCommit: {}}).
			WithUnreadable(headCommit)

		// when
		result := execute(trees, doubles.NewStubRevisionsRepository(headCommit, baseCommit), goRequest())

		// then
		require.Equal(t, "OnError", result.called)
		assert.ErrorIs(t, result.err, doubles.ErrUnreadable)
	})
}
