package entities_test

import (
	"regexp"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/rios0rios0/pipelines/global/scripts/tools/test-pyramid/internal/domain/entities"
)

// classified is one file a profile must put in a tier, for a reason, with a number of test cases.
type classified struct {
	name     string
	language string
	path     string
	content  string
	tier     entities.Tier
	reason   string
	cases    int
}

func assertClassified(t *testing.T, cases []classified) {
	t.Helper()
	for _, example := range cases {
		t.Run(example.name, func(t *testing.T) {
			t.Parallel()
			// given
			profile, known := entities.Profiles()[example.language]
			require.True(t, known, example.language)
			files := []entities.TestFile{{Path: example.path, Content: example.content}}

			// when
			classification := profile.Classify(files, nil)

			// then
			require.Len(t, classification.Files, 1)
			assert.Equal(t, entities.FileTier{
				Path: example.path, Tier: example.tier, Cases: example.cases, Reason: example.reason,
			}, classification.Files[0])
		})
	}
}

func TestProfilesGo(t *testing.T) {
	t.Parallel()
	assertClassified(t, []classified{
		{
			"should count Go tests and suite methods but not TestMain or a helper as unit tests by default",
			"go",
			"pkg/a_test.go",
			"package pkg\n\nfunc TestA(t *testing.T) {}\nfunc TestMain(m *testing.M) {}\nfunc (s *Suite) TestB() {}\nfunc Testable() {}\n",
			entities.TierUnit,
			"default",
			2,
		},
		{
			"should put a file tagged integration in the integration tier",
			"go",
			"pkg/repo_test.go",
			"//go:build integration\n\npackage pkg\n\nfunc TestRepo(t *testing.T) {}\n",
			entities.TierIntegration,
			"evidence",
			1,
		},
		{"should not read a negated tag as a declaration", "go", "pkg/b_test.go",
			"//go:build !integration\n\npackage pkg\n\nfunc TestB(t *testing.T) {}\n", entities.TierUnit, "default", 1},
		{
			"should put the highest tier a combined tag names",
			"go",
			"pkg/c_test.go",
			"//go:build integration && e2e\n\npackage pkg\n\nfunc TestC(t *testing.T) {}\n",
			entities.TierE2E,
			"evidence",
			1,
		},
		{
			"should put an untagged file that imports Testcontainers in the integration tier",
			"go",
			"pkg/d_test.go",
			"package pkg\n\nimport (\n\t\"testing\"\n\n\tpg \"github.com/testcontainers/testcontainers-go/modules/postgres\"\n)\n\nfunc TestD(t *testing.T) {}\n",
			entities.TierIntegration,
			"evidence",
			1,
		},
		{
			"should put a browser driver in the e2e tier",
			"go",
			"web/e_test.go",
			"package web\n\nimport \"github.com/chromedp/chromedp\"\n\nfunc TestE(t *testing.T) {}\n",
			entities.TierE2E,
			"evidence",
			1,
		},
		{"should not read a Go path as a tier, the build tag deciding alone", "go", "test/e2e/flow_test.go",
			"package e2e\n\nfunc TestFlow(t *testing.T) {}\n", entities.TierUnit, "default", 1},
	})
}

func TestProfilesPython(t *testing.T) {
	t.Parallel()
	assertClassified(t, []classified{
		{
			"should count test functions, async ones included, as unit tests by default",
			"python",
			"tests/unit/test_math.py",
			"def test_add():\n    pass\n\nasync def test_wait():\n    pass\n\ndef helper():\n    pass\n",
			entities.TierUnit,
			"default",
			2,
		},
		{
			"should put a test under an integration directory in the integration tier",
			"python",
			"tests/integration/test_db.py",
			"def test_db():\n    pass\n",
			entities.TierIntegration,
			"path",
			1,
		},
		{
			"should put a test that drives the application through FastAPI's TestClient in the functional tier, whatever its directory",
			"python",
			"tests/unit/test_api.py",
			"from fastapi.testclient import TestClient\n\ndef test_root():\n    pass\n",
			entities.TierFunctional,
			"evidence",
			1,
		},
		{"should read a pytest marker as a declaration", "python", "tests/test_flow.py",
			"import pytest\n\n@pytest.mark.e2e\ndef test_flow():\n    pass\n", entities.TierE2E, "evidence", 1},
		{
			"should put a test that reaches Django's database in the integration tier",
			"python",
			"app/tests.py",
			"import pytest\n\n@pytest.mark.django_db\ndef test_model():\n    pass\n",
			entities.TierIntegration,
			"evidence",
			1,
		},
		{"should read Google's large size as end-to-end", "python", "tests/test_size.py",
			"@pytest.mark.large\ndef test_big():\n    pass\n", entities.TierE2E, "evidence", 1},
	})
}

func TestProfilesJava(t *testing.T) {
	t.Parallel()
	assertClassified(t, []classified{
		{
			"should count JUnit tests, not other annotations, as unit tests by default",
			"java",
			"src/test/java/com/acme/MathTest.java",
			"class MathTest {\n  @Test\n  void adds() {}\n  @ParameterizedTest\n  void many(int x) {}\n  @TestConfiguration\n  static class C {}\n}\n",
			entities.TierUnit,
			"default",
			2,
		},
		{"should put a Failsafe-named class in the integration tier", "java", "src/test/java/com/acme/RepoIT.java",
			"class RepoIT {\n  @Test void saves() {}\n}\n", entities.TierIntegration, "path", 1},
		{
			"should put a test of the integrationTest source set in the integration tier",
			"java",
			"src/integrationTest/kotlin/com/acme/Repo.kt",
			"class Repo {\n  @Test fun saves() {}\n}\n",
			entities.TierIntegration,
			"path",
			1,
		},
		{
			"should put a test that uses Testcontainers in the integration tier",
			"java",
			"src/test/java/com/acme/RepoTest.java",
			"import org.testcontainers.containers.PostgreSQLContainer;\n\n@Testcontainers\nclass RepoTest {\n  @Test void saves() {}\n}\n",
			entities.TierIntegration,
			"evidence",
			1,
		},
		{
			"should put a test that drives the application through MockMvc in the functional tier",
			"java",
			"src/test/java/com/acme/ApiTest.java",
			"import org.springframework.test.web.servlet.MockMvc;\n\n@SpringBootTest\nclass ApiTest {\n  @Test void lists() {}\n}\n",
			entities.TierFunctional,
			"evidence",
			1,
		},
		{
			"should put a browser driver in the e2e tier",
			"java",
			"src/test/java/com/acme/LoginTest.java",
			"import org.openqa.selenium.WebDriver;\n\nclass LoginTest {\n  @Test void logsIn() {}\n}\n",
			entities.TierE2E,
			"evidence",
			1,
		},
		{"should read a JUnit tag as a declaration", "java", "src/test/java/com/acme/FlowTest.java",
			"@Tag(\"e2e\")\nclass FlowTest {\n  @Test void flows() {}\n}\n", entities.TierE2E, "evidence", 1},
		{"should count Spock features", "java", "src/test/groovy/com/acme/MathSpec.groovy",
			"class MathSpec extends Specification {\n  def \"adds numbers\"() {\n  }\n  def 'subtracts'() {\n  }\n}\n",
			entities.TierUnit, "default", 2},
	})
}

func TestProfilesJavaScript(t *testing.T) {
	t.Parallel()
	assertClassified(t, []classified{
		{
			"should count tests, their modifiers and each tables, not describe blocks, as unit tests by default",
			"javascript",
			"src/sum.test.ts",
			"describe('sum', () => {\n  it('adds', () => {});\n  test.each([1, 2])('x %i', () => {});\n  it.skip(`later`, () => {});\n" +
				"  test.describe('nested', () => {});\n  test.beforeEach(() => {});\n});\n",
			entities.TierUnit,
			"default",
			3,
		},
		{
			"should put a Playwright test in the e2e tier",
			"javascript",
			"tests/login.spec.ts",
			"import { test, expect } from '@playwright/test';\n\ntest('logs in', async ({ page }) => {});\n",
			entities.TierE2E,
			"evidence",
			1,
		},
		{"should put a Cypress test that visits a page in the e2e tier", "javascript", "src/login.cy.ts",
			"it('visits', () => {\n  cy.visit('/');\n});\n", entities.TierE2E, "evidence", 1},
		{
			"should put a supertest test in the functional tier",
			"javascript",
			"test/api.test.js",
			"const request = require('supertest');\n\nit('responds', async () => {});\n",
			entities.TierFunctional,
			"evidence",
			1,
		},
		{"should put an .int.test file in the integration tier", "javascript", "src/db.int.test.ts",
			"it('connects', () => {});\n", entities.TierIntegration, "path", 1},
		{"should keep a Playwright component test with the unit tests", "javascript", "src/Button.spec.tsx",
			"import { test } from '@playwright/experimental-ct-react';\n\ntest('renders', async ({ mount }) => {});\n",
			entities.TierUnit, "default", 1},
		{
			"should not read a directory named like a tier inside another word",
			"javascript",
			"src/integrations/slack.test.ts",
			"it('posts', () => {});\n",
			entities.TierUnit,
			"default",
			1,
		},
		{
			"should read a tier word joined to others in a directory name",
			"javascript",
			"packages/app/e2e-tests/flow.test.ts",
			"it('flows', () => {});\n",
			entities.TierE2E,
			"path",
			1,
		},
	})
}

func TestProfilesPHP(t *testing.T) {
	t.Parallel()
	assertClassified(t, []classified{
		{"should count a method once however it is marked, and not a helper", "php", "tests/Unit/MathTest.php",
			"<?php\nclass MathTest extends TestCase\n{\n    public function testAdds(): void {}\n    /** @test */\n" +
				"    public function it_subtracts(): void {}\n    #[Test]\n    public function testDoubles(): void {}\n" +
				"    private function helper(): void {}\n}\n",
			entities.TierUnit, "default", 3},
		{"should count Pest tests", "php", "tests/Unit/SumTest.php",
			"<?php\nit('adds', function () {});\ntest('subtracts', fn () => true);\n", entities.TierUnit, "default", 2},
		{
			"should put Laravel's feature tests in the functional tier",
			"php",
			"tests/Feature/UserTest.php",
			"<?php\nclass UserTest extends TestCase\n{\n    public function testShows(): void {}\n}\n",
			entities.TierFunctional,
			"path",
			1,
		},
		{
			"should put a test that makes an HTTP request of the application in the functional tier",
			"php",
			"tests/Unit/ApiTest.php",
			"<?php\nclass ApiTest extends TestCase\n{\n    public function testLists(): void\n    {\n        $this->getJson('/api/users');\n    }\n}\n",
			entities.TierFunctional,
			"evidence",
			1,
		},
		{
			"should put a test that resets a real database in the integration tier",
			"php",
			"tests/Unit/RepoTest.php",
			"<?php\nclass RepoTest extends TestCase\n{\n    use RefreshDatabase;\n\n    public function testSaves(): void {}\n}\n",
			entities.TierIntegration,
			"evidence",
			1,
		},
		{
			"should put a Dusk test in the e2e tier",
			"php",
			"tests/LoginTest.php",
			"<?php\nclass LoginTest extends DuskTestCase\n{\n    public function testLogsIn(): void {}\n}\n",
			entities.TierE2E,
			"evidence",
			1,
		},
		{
			"should put a Pest browser test in the e2e tier, whatever database it also resets",
			"php",
			"tests/v4/Browser/LoginTest.php",
			"<?php\nuses(RefreshDatabase::class);\n\nit('logs in', function () {\n    $page = visit('/login');\n});\n",
			entities.TierE2E,
			"evidence",
			1,
		},
		{
			"should not read BrowserKit's in-process visit as a browser",
			"php",
			"tests/Unit/LegacyTest.php",
			"<?php\nclass LegacyTest extends TestCase\n{\n    public function testHome(): void\n    {\n        $this->visit('/');\n    }\n}\n",
			entities.TierUnit,
			"default",
			1,
		},
		{
			"should read a nested Feature directory as functional",
			"php",
			"tests/v4/Feature/ServerTest.php",
			"<?php\nit('lists servers', function () {});\n",
			entities.TierFunctional,
			"path",
			1,
		},
	})
}

func TestProfilesRuby(t *testing.T) {
	t.Parallel()
	assertClassified(t, []classified{
		{
			"should count examples in every RSpec form as unit tests by default",
			"ruby",
			"spec/models/user_spec.rb",
			"describe User do\n  it 'validates' do\n  end\n  it { is_expected.to be_valid }\n  context 'x' do\n    specify { }\n  end\nend\n",
			entities.TierUnit,
			"default",
			3,
		},
		{"should put a request spec in the functional tier", "ruby", "spec/requests/users_spec.rb",
			"describe 'users' do\n  it 'lists' do\n  end\nend\n", entities.TierFunctional, "path", 1},
		{"should put a system spec in the e2e tier", "ruby", "spec/system/login_spec.rb",
			"describe 'login' do\n  it 'logs in' do\n  end\nend\n", entities.TierE2E, "path", 1},
		{
			"should read the spec type as a declaration",
			"ruby",
			"spec/services/api_spec.rb",
			"RSpec.describe Api, type: :request do\n  it 'answers' do\n  end\nend\n",
			entities.TierFunctional,
			"evidence",
			1,
		},
		{
			"should put a Rails integration test, which drives the routes, in the functional tier",
			"ruby",
			"test/integration/flow_test.rb",
			"class FlowTest < ActionDispatch::IntegrationTest\n  test 'flows' do\n  end\nend\n",
			entities.TierFunctional,
			"evidence",
			1,
		},
		{"should count Minitest methods", "ruby", "test/models/user_test.rb",
			"class UserTest < Minitest::Test\n  def test_valid\n  end\nend\n", entities.TierUnit, "default", 1},
	})
}

func TestProfilesDotnet(t *testing.T) {
	t.Parallel()
	assertClassified(t, []classified{
		{
			"should count one test per method, however many attributes mark it",
			"dotnet",
			"tests/App.UnitTests/MathTests.cs",
			"public class MathTests\n{\n    [Fact]\n    public void Adds() {}\n    [Theory]\n    [InlineData(1)]\n    [InlineData(2)]\n" +
				"    public void Many(int x) {}\n    [Fact] public void Inline() {}\n    [TestCase(1)]\n    [TestCase(2)]\n" +
				"    public void Cases(int x) {}\n    public void Helper() {}\n}\n",
			entities.TierUnit,
			"default",
			4,
		},
		{
			"should put a test of an integration test project in the integration tier",
			"dotnet",
			"tests/App.IntegrationTests/RepoTests.cs",
			"public class RepoTests\n{\n    [Fact]\n    public void Saves() {}\n}\n",
			entities.TierIntegration,
			"path",
			1,
		},
		{"should read a test category as a declaration", "dotnet", "tests/App.Tests/FlowTests.cs",
			"[Trait(\"Category\", \"E2E\")]\npublic class FlowTests\n{\n    [Fact]\n    public void Flows() {}\n}\n",
			entities.TierE2E, "evidence", 1},
		{
			"should put a test that hosts the application in WebApplicationFactory in the functional tier",
			"dotnet",
			"tests/App.Tests/ApiTests.cs",
			"public class ApiTests : IClassFixture<WebApplicationFactory<Program>>\n{\n    [Fact]\n    public async Task Lists() {}\n}\n",
			entities.TierFunctional,
			"evidence",
			1,
		},
		{
			"should put a test that uses Testcontainers in the integration tier",
			"dotnet",
			"tests/App.Tests/DbTests.cs",
			"using Testcontainers.PostgreSql;\n\npublic class DbTests\n{\n    [Fact]\n    public void Connects() {}\n}\n",
			entities.TierIntegration,
			"evidence",
			1,
		},
	})
}

func TestProfilesDart(t *testing.T) {
	t.Parallel()
	assertClassified(t, []classified{
		{
			"should count tests, widget tests and bloc tests, not groups, as unit tests by default",
			"dart",
			"test/counter_test.dart",
			"void main() {\n  group('counter', () {\n    test('adds', () {});\n    testWidgets('renders', (tester) async {});\n" +
				"    blocTest<CounterBloc, int>('emits', build: CounterBloc.new);\n  });\n}\n",
			entities.TierUnit,
			"default",
			3,
		},
		{
			"should put Flutter's integration_test directory in the e2e tier",
			"dart",
			"integration_test/app_test.dart",
			"import 'package:integration_test/integration_test.dart';\n\nvoid main() {\n  testWidgets('flows', (tester) async {});\n}\n",
			entities.TierE2E,
			"evidence",
			1,
		},
		{
			"should put a test under an integration directory in the integration tier",
			"dart",
			"test/integration/api_test.dart",
			"void main() {\n  test('calls', () {});\n}\n",
			entities.TierIntegration,
			"path",
			1,
		},
	})
}

func TestProfilesTerraform(t *testing.T) {
	t.Parallel()
	assertClassified(t, []classified{
		{"should put every run of a mocked file in the unit tier", "terraform", "modules/net/tests/smoke.tftest.hcl",
			"mock_provider \"azurerm\" {}\n\nrun \"plans\" {\n  command = plan\n}\n\nrun \"applies\" {\n}\n",
			entities.TierUnit, "mocked", 2},
		{"should put an apply-time run in the e2e tier under tests/e2e", "terraform", "tests/e2e/cluster.tftest.hcl",
			"run \"cluster\" {\n}\n", entities.TierE2E, "path", 1},
		{
			"should put a Terratest test that applies in the e2e tier",
			"terraform",
			"tests/terratest/app_test.go",
			"package test\n\nfunc TestApp(t *testing.T) {\n\tterraform.InitAndApply(t, options)\n}\n",
			entities.TierE2E,
			"evidence",
			1,
		},
		{
			"should keep a Terratest test that reads HCL offline with the unit tests",
			"terraform",
			"tests/terratest/hcl_test.go",
			"package test\n\nfunc TestHCL(t *testing.T) {}\nfunc TestMain(m *testing.M) {}\n",
			entities.TierUnit,
			"default",
			1,
		},
	})

	t.Run("should give each run without mocks the tier its command gives it", func(t *testing.T) {
		t.Parallel()
		// given
		profile := entities.Profiles()["terraform"]
		files := []entities.TestFile{
			{
				Path:    "modules/net/tests/mixed.tftest.hcl",
				Content: "run \"plans\" {\n  command = plan\n}\n\nrun \"applies\" {\n  assert {\n  }\n}\n\nrun \"applies too\" {\n  command = apply\n}\n",
			},
		}

		// when
		classification := profile.Classify(files, nil)

		// then
		assert.Equal(t, []entities.FileTier{
			{Path: files[0].Path, Tier: entities.TierUnit, Cases: 1, Reason: "plan"},
			{Path: files[0].Path, Tier: entities.TierIntegration, Cases: 2, Reason: "apply"},
		}, classification.Files)
	})
}

func TestProfileRules(t *testing.T) {
	t.Parallel()

	t.Run("should let the repository's first matching rule decide, lowering a tier if it says so", func(t *testing.T) {
		t.Parallel()
		// given
		profile := entities.Profiles()["javascript"]
		files := []entities.TestFile{
			{
				Path:    "e2e/smoke.spec.ts",
				Content: "import { test } from '@playwright/test';\ntest('loads', () => {});\n",
			},
		}
		rules := []entities.PathRule{
			{Tier: entities.TierUnit, Pattern: regexp.MustCompile(`^e2e/smoke`)},
			{Tier: entities.TierIntegration, Pattern: regexp.MustCompile(`^e2e/`)},
		}

		// when
		classification := profile.Classify(files, rules)

		// then
		require.Len(t, classification.Files, 1)
		assert.Equal(t, entities.TierUnit, classification.Files[0].Tier)
		assert.Equal(t, "rule 1", classification.Files[0].Reason)
	})

	t.Run("should leave a file an ignore rule names out of the pyramid", func(t *testing.T) {
		t.Parallel()
		// given
		profile := entities.Profiles()["go"]
		files := []entities.TestFile{
			{Path: "bench/load_test.go", Content: "func TestLoad(t *testing.T) {}\n"},
			{Path: "pkg/a_test.go", Content: "func TestA(t *testing.T) {}\n"},
		}
		rules := []entities.PathRule{{Tier: entities.TierIgnored, Pattern: regexp.MustCompile(`^bench/`)}}

		// when
		classification := profile.Classify(files, rules)

		// then
		assert.Equal(t, 1, classification.Counts.Total())
		assert.Equal(t, 1, classification.Counts.Of(entities.TierIgnored))
	})

	t.Run("should not read files outside the profile, nor excluded ones", func(t *testing.T) {
		t.Parallel()
		// given
		profile := entities.Profiles()["javascript"]
		files := []entities.TestFile{
			{Path: "node_modules/lib/a.test.js", Content: "it('x', () => {});\n"},
			{Path: "src/app.ts", Content: "it('not a test file', () => {});\n"},
		}

		// when
		classification := profile.Classify(files, nil)

		// then
		assert.Empty(t, classification.Files)
		assert.Zero(t, classification.Counts.Total())
	})
}
