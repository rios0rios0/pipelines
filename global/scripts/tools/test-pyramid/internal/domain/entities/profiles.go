package entities

import "regexp"

// Profiles are the classification rules of every language the pipelines test, by the name the
// templates give it (`TEST_PYRAMID_LANGUAGE`, `languages` in `.test-pyramid`). Adding a language is
// adding a profile here; nothing that reads them changes.
func Profiles() map[string]Profile {
	shared := sharedConventions()
	profiles := map[string]Profile{}
	for _, profile := range []Profile{
		goProfile(),
		pythonProfile(shared),
		javaProfile(shared),
		javascriptProfile(shared),
		phpProfile(shared),
		rubyProfile(shared),
		dotnetProfile(shared),
		dartProfile(shared),
		terraformProfile(shared),
	} {
		profiles[profile.Language] = profile
	}
	return profiles
}

// sharedConventions are the naming conventions every language but Go shares, matched on the
// lower-cased directory and file name, and on the file name as written for CamelCase.
func sharedConventions() []PathConvention {
	convention := func(tier Tier, words, tokens, camel string) PathConvention {
		return PathConvention{
			Tier:      tier,
			Directory: regexp.MustCompile(`(^|/)([^/]*[._-])?(` + words + `)([._-][^/]*)?/`),
			Token:     regexp.MustCompile(`(^|[._-])(` + tokens + `)[._-]`),
			Camel:     regexp.MustCompile(`(^|[a-z0-9])(` + camel + `)\.\w+$`),
		}
	}
	return []PathConvention{
		convention(
			TierE2E,
			`e2e|e2etests?|end-to-end|end_to_end|endtoend|endtoendtests?|acceptance|acceptancetests?|uitests?|ui-tests?|ui_tests?`,
			`e2e|end-to-end|end_to_end|endtoend|acceptance`,
			`(E2E|E2e|EndToEnd|Acceptance)(Test|Tests|Spec|Specs|IT)?`,
		),
		convention(TierFunctional,
			`functional|functionaltests?`,
			`functional`,
			`Functional(Test|Tests|Spec|Specs)`),
		convention(TierIntegration,
			`integration|integrationtests?`,
			`integration`,
			`Integration(Test|Tests|Spec|Specs)|IT|ITCase`),
	}
}

// evidence compiles a profile's evidence patterns, an empty one naming nothing.
func evidence(integration, functional, e2e string) [tierCount]*regexp.Regexp {
	return compileByTier(integration, functional, e2e)
}

// paths compiles a profile's path conventions, an empty one naming nothing.
func paths(integration, functional, e2e string) [tierCount]*regexp.Regexp {
	return compileByTier(integration, functional, e2e)
}

func compileByTier(integration, functional, e2e string) [tierCount]*regexp.Regexp {
	var compiled [tierCount]*regexp.Regexp
	for tier, pattern := range [tierCount]string{TierIntegration: integration, TierFunctional: functional, TierE2E: e2e} {
		if pattern != "" {
			compiled[tier] = regexp.MustCompile(pattern)
		}
	}
	return compiled
}

// goProfile: the build tag decides the tier, as it decides which phase of the Go runner runs the
// test. Untagged is a unit test; `//go:build integration` an integration test, and `functional` and
// `e2e` their tiers; a negated tag (`!integration`) declares nothing. Paths are not read: a package
// named `integration` holds whatever its tags say.
func goProfile() Profile {
	tag := func(name string) string {
		return `^//(go:build|\s*\+build)\s(.*[^!\w.])?` + name + `([^\w.]|$)`
	}
	imports := func(modules string) string {
		return `^\s*(import\s+)?([\w.]+\s+)?"(` + modules + `)`
	}
	return Profile{
		Language: "go",
		Files:    regexp.MustCompile(`(^|/)[^/]+_test\.go$`),
		Exclude:  regexp.MustCompile(`(^|/)(vendor|testdata|third_party|node_modules)/`),
		Dialect:  DialectLine,
		Cases:    regexp.MustCompile(`^func\s+(\([^)]*\)\s*)?Test([^a-z]|$)`),
		Skip:     regexp.MustCompile(`^func\s+TestMain\s*\(`),
		Evidence: evidence(
			tag(
				"integration",
			)+`|`+imports(
				`github\.com/(testcontainers/testcontainers-go|ory/dockertest|fergusstrange/embedded-postgres|peterldowns/pgtestdb|DATA-DOG/go-txdb)`,
			),
			tag("functional")+`|`+imports(`github\.com/(gavv/httpexpect|steinfletcher/apitest)`),
			tag(
				"e2e",
			)+`|`+imports(
				`github\.com/(chromedp/chromedp|go-rod/rod|playwright-community/playwright-go|tebeka/selenium|sclevine/agouti)`,
			),
		),
	}
}

// pythonProfile: a pytest marker declares the tier, pytest-test-categories' Google sizes included
// (`medium` integration, `large` and `xlarge` end-to-end, as Bazel sizes them); a Django test marked
// `django_db` reaches a real database, an integration test by Google's definition. An in-process
// client of the application (FastAPI's and Starlette's `TestClient`, Django's and Flask's test
// clients) is functional.
func pythonProfile(shared []PathConvention) Profile {
	mark := func(names string) string { return `pytest\.mark\.(` + names + `)\b` }
	imports := func(modules string) string { return `^\s*(from|import)\s+(` + modules + `)([.\s,]|$)` }
	return Profile{
		Language: "python",
		Files:    regexp.MustCompile(`(^|/)(test_[^/]*|[^/]*_test|tests)\.py$|(^|/)tests?/([^/]+/)*[^/]+\.py$`),
		Exclude: regexp.MustCompile(
			`(^|/)(\.?venv|\.tox|\.nox|site-packages|node_modules|build|dist|__pypackages__)/`,
		),
		Dialect: DialectLine,
		Cases:   regexp.MustCompile(`^\s*(async\s+)?def\s+test`),
		Evidence: evidence(
			mark(
				`integration|medium|django_db`,
			)+`|`+imports(
				`testcontainers|pytest_postgresql|testing\.postgresql|pytest_mysql|pytest_redis|pytest_mongodb`,
			),
			mark(`functional`)+`|`+imports(`fastapi\.testclient|starlette\.testclient|webtest|flask\.testing`)+
				`|\.test_client\(|self\.client\.(get|post|put|patch|delete|head|options)\(`+
				`|^\s*from\s+(django\.test|rest_framework\.test)\s+import\s.*\b(Client|APITestCase|LiveServerTestCase)\b`,
			mark(
				`e2e|end_to_end|acceptance|ui|browser|large|xlarge`,
			)+`|`+imports(
				`playwright|selenium|seleniumbase|splinter|pyppeteer|appium|helium`,
			),
		),
		Conventions: shared,
	}
}

// javaProfile, for Java, Kotlin and Groovy: a Gradle source set or a Maven Failsafe name is the
// convention (`src/integrationTest/`, `*IT.java`), a JUnit tag or category the declaration. A test
// that starts Spring's application context, a database slice or Testcontainers is an integration
// test; one that drives the application through its HTTP layer (MockMvc, WebTestClient,
// RestAssured) a functional test; a browser or a device driver an end-to-end test.
func javaProfile(shared []PathConvention) Profile {
	tag := func(names string) string { return `@Tags?\([^)]*"(` + names + `)"` }
	imports := func(packages string) string { return `^\s*import\s+(static\s+)?(` + packages + `)\.` }
	annotation := func(names string) string { return `@(` + names + `)\b` }
	return Profile{
		Language: "java",
		Files: regexp.MustCompile(
			`(^|/)src/([\w-]*([Tt]est|IT|[Ii]ntegration|[Ee]2[Ee]|[Ff]unctional|[Aa]cceptance)[\w-]*|it)/.*\.(java|kt|groovy)$`,
		),
		Exclude: regexp.MustCompile(`(^|/)(build|target|out|bin|\.gradle|node_modules)/`),
		Dialect: DialectLine,
		Cases: regexp.MustCompile(
			`^\s*@(org\.junit\.(jupiter\.api\.)?|org\.testng\.annotations\.)?(Test|ParameterizedTest|RepeatedTest|TestFactory|TestTemplate)(\s|\(|$)` +
				`|^\s*def\s+["'][^"']+["']\s*\(`,
		),
		Evidence: evidence(
			tag(`integration|it|IT`)+`|@Category\([^)]*Integration`+
				`|`+imports(`org\.testcontainers|com\.github\.tomakehurst\.wiremock|org\.wiremock|io\.zonky\.test|de\.flapdoodle\.embed`)+
				`|`+annotation(`Testcontainers|SpringBootTest|DataJpaTest|DataJdbcTest|JdbcTest|JooqTest|DataMongoTest|DataRedisTest|DataR2dbcTest|DataCassandraTest|DataElasticsearchTest|DataNeo4jTest|DataLdapTest|EmbeddedKafka|MicronautTest`),
			tag(`functional`)+`|@Category\([^)]*Functional`+
				`|`+imports(`org\.springframework\.test\.web\.servlet|org\.springframework\.test\.web\.reactive\.server|org\.springframework\.boot\.test\.web\.client|io\.restassured|io\.ktor\.server\.testing`)+
				`|`+annotation(`WebMvcTest|WebFluxTest|AutoConfigureMockMvc|AutoConfigureWebTestClient|QuarkusTest|QuarkusIntegrationTest|GraphQlTest`)+
				`|@SpringBootTest\([^)]*webEnvironment`,
			tag(`e2e|E2E|end-to-end|acceptance|ui|browser`)+`|@Category\([^)]*(E2E|EndToEnd|Acceptance)`+
				`|`+imports(`org\.openqa\.selenium|com\.codeborne\.selenide|com\.microsoft\.playwright|io\.appium|androidx\.test\.espresso|androidx\.test\.uiautomator|io\.github\.bonigarcia\.wdm`),
		),
		Paths: paths(
			`(^|/)src/([\w-]*([Ii]ntegration|IT)[\w-]*|it|androidTest)/|(^|/)(IT[A-Z][^/]*|[^/]*[a-z0-9](IT|ITCase))\.(java|kt|groovy)$`,
			`(^|/)src/[\w-]*[Ff]unctional[\w-]*/`,
			`(^|/)src/[\w-]*([Ee]2[Ee]|[Aa]cceptance)[\w-]*/`,
		),
		Conventions: shared,
	}
}

// javascriptProfile, for JavaScript and TypeScript (Jest, Vitest, Mocha, Jasmine, Cypress,
// Playwright): a browser driver is end-to-end (Playwright's runner, Cypress navigating with
// `cy.visit`, WebdriverIO, Puppeteer, Selenium); an in-process HTTP client of the application
// (supertest, NestJS's `createNestApplication`) functional; a database container integration.
// Component tests mount one component and stay unit tests: neither `cy.mount` nor
// `@playwright/experimental-ct-*` is a signature.
func javascriptProfile(shared []PathConvention) Profile {
	module := func(names string) string {
		return `(^|[^\w$.])(from\s*|require\(\s*|import\(\s*|import\s+)["'](` + names + `)["'/]`
	}
	return Profile{
		Language: "javascript",
		Files: regexp.MustCompile(`(^|/)[^/]+\.(test|spec|cy|e2e)\.[cm]?[jt]sx?$` +
			`|(^|/)(__tests__|tests?|e2e|cypress|playwright)/([^/]+/)*[^/]+\.[cm]?[jt]sx?$`),
		Exclude: regexp.MustCompile(
			`(^|/)(node_modules|dist|build|coverage|out|\.next|\.nuxt|\.svelte-kit|\.output|\.yarn|vendor|storybook-static)/`,
		),
		Dialect: DialectLine,
		Cases: regexp.MustCompile(
			`^\s*(it|test|specify|xit|fit|xtest)(\.(only|skip|todo|concurrent|failing|fails|fixme|sequential|serial))*\s*\(\s*["'\x60]` +
				`|^\s*(it|test)(\.(only|skip|concurrent|sequential))*\.each\s*[(\x60]`,
		),
		Evidence: evidence(
			module(
				`testcontainers|@testcontainers/[a-z0-9-]+|mongodb-memory-server|mongodb-memory-server-core`,
			)+`|@group\s+integration\b`,
			module(`supertest|light-my-request|pactum|frisby`)+`|\.createNestApplication\(|@group\s+functional\b`,
			module(
				`@playwright/test|playwright|playwright-core|playwright-chromium|playwright-firefox|playwright-webkit|puppeteer|puppeteer-core|selenium-webdriver|webdriverio|@wdio/globals|testcafe|detox|nightwatch|appium`,
			)+
				`|cy\.visit\(|@group\s+(e2e|acceptance)\b`,
		),
		Paths: paths(
			`\.(int|integration)\.(test|spec)\.[cm]?[jt]sx?$`,
			`\.functional\.(test|spec)\.[cm]?[jt]sx?$`,
			`(^|/)(cypress|playwright)/`,
		),
		Conventions: shared,
	}
}

// phpProfile, for PHPUnit and Pest: Laravel's `tests/Feature/` boots the framework and makes HTTP
// requests, functional; a test that resets a real database (`RefreshDatabase`) or boots Symfony's
// kernel without a client is an integration test; Dusk and Panther drive a browser.
func phpProfile(shared []PathConvention) Profile {
	group := func(names string) string { return `(@group\s+|#\[Group\(\s*["'])(` + names + `)\b` }
	// A docblock's `@test`, on a line of its own or in a one-line `/** @test */`, or the attribute.
	marker := `^\s*(/?\*+\s*@test(\s|\*|$)|#\[([\w\\]*\\)?Test([\],(]|$))`
	return Profile{
		Language: "php",
		Files:    regexp.MustCompile(`(^|/)tests?/([^/]+/)*[^/]+\.php$|(^|/)[^/]+Test\.php$`),
		Exclude:  regexp.MustCompile(`(^|/)(vendor|node_modules|var|storage|bootstrap/cache|\.phpunit\.cache)/`),
		Dialect:  DialectMarker,
		Marker:   regexp.MustCompile(marker),
		Declaration: regexp.MustCompile(
			`^\s*((public|protected|private|static|final|abstract)\s+)*function\s+[A-Za-z_]`,
		),
		Self: regexp.MustCompile(
			`^\s*((public|protected|private|static|final)\s+)*function\s+test|^\s*(it|test)\s*\(\s*["']`,
		),
		Evidence: evidence(
			group(`integration`)+
				`|Illuminate\\Foundation\\Testing\\(RefreshDatabase|DatabaseMigrations|DatabaseTransactions|DatabaseTruncation|LazilyRefreshDatabase)`+
				`|^\s*use\s+(RefreshDatabase|DatabaseMigrations|DatabaseTransactions|DatabaseTruncation|LazilyRefreshDatabase)[\s;,]`+
				`|(extends|use)\s+[\w\\]*KernelTestCase\b|^\s*use\s+Testcontainers\\`,
			group(`functional|feature`)+
				`|\$this->(get|post|put|patch|delete|options|json|call|getJson|postJson|putJson|patchJson|deleteJson|optionsJson)\(`+
				`|(extends|use)\s+[\w\\]*WebTestCase\b|(static|self)::createClient\(`,
			// Pest's browser plugin drives a real browser through the global `visit()`, a function
			// call rather than a method (`$this->visit()` is BrowserKit's in-process crawler).
			group(`e2e|acceptance|browser`)+
				`|(extends|use)\s+[\w\\]*(DuskTestCase|PantherTestCase)\b|\$this->browse\(|(^|[^\w>:$])visit\(`+
				`|^\s*use\s+(Facebook\\WebDriver|Symfony\\Component\\Panther|Laravel\\Dusk)`,
		),
		Paths: paths(
			`(^|/)tests?/([^/]+/)*Integration/`,
			`(^|/)tests?/([^/]+/)*(Feature|Functional)/`,
			`(^|/)tests?/([^/]+/)*(Browser|Acceptance|E2E)/`,
		),
		Conventions: shared,
	}
}

// rubyProfile, for RSpec and Minitest: RSpec's spec types and Rails' test classes declare the tier.
// `ActionDispatch::IntegrationTest` drives the whole application through its routes, below the
// browser: functional by scope, whatever Rails calls it. System tests and Capybara features drive
// the UI: end-to-end.
func rubyProfile(shared []PathConvention) Profile {
	return Profile{
		Language: "ruby",
		Files: regexp.MustCompile(
			`(^|/)spec/([^/]+/)*[^/]+_spec\.rb$|(^|/)test/([^/]+/)*([^/]+_test|test_[^/]+)\.rb$`,
		),
		Exclude: regexp.MustCompile(`(^|/)(vendor|node_modules|tmp|log|coverage)/`),
		Dialect: DialectLine,
		Cases: regexp.MustCompile(
			`^\s*(it|specify|example|scenario|its|xit|xspecify|xexample|xscenario|fit|fspecify|fexample|fscenario)(\s|\(|\{|$)` +
				`|^\s*def\s+test_|^\s*test\s+["']`,
		),
		Evidence: evidence(
			`type:\s*:integration\b|^\s*require\s+["']testcontainers|Testcontainers::`,
			`type:\s*:(request|controller)\b|<\s*(ActionDispatch::IntegrationTest|ActionController::TestCase)|include\s+Rack::Test::Methods`,
			`type:\s*:(system|feature)\b|js:\s*true|<\s*(ApplicationSystemTestCase|ActionDispatch::SystemTestCase)`+
				`|^\s*visit[\s(]|^\s*feature\s+["']|^\s*require\s+["'](capybara|selenium-webdriver|watir|cuprite|ferrum)`,
		),
		Paths: paths(
			``,
			`(^|/)spec/(requests?|controllers|api)/|(^|/)test/(controllers|integration)/`,
			`(^|/)(spec|test)/(system|features?|e2e|acceptance)/`,
		),
		Conventions: shared,
	}
}

// dotnetProfile, for xUnit, NUnit and MSTest: a test category declares the tier
// (`[Trait("Category", "Integration")]`, `[Category("E2E")]`, `[TestCategory("Functional")]`), and
// so does the project a test lives in (`*.IntegrationTests`, `*.E2ETests`). `WebApplicationFactory`
// and `TestServer` host the application in memory and drive it through HTTP: functional.
func dotnetProfile(shared []PathConvention) Profile {
	category := func(names string) string { return `(Trait|Category|TestCategory)\([^)]*"(` + names + `)"` }
	using := func(namespaces string) string { return `^\s*using\s+(static\s+)?(` + namespaces + `)([.;\s]|$)` }
	return Profile{
		Language: "dotnet",
		Files:    regexp.MustCompile(`\.cs$`),
		Exclude:  regexp.MustCompile(`(^|/)(bin|obj|packages|node_modules|TestResults|\.vs)/`),
		Dialect:  DialectMarker,
		Marker: regexp.MustCompile(
			`^\s*\[([^\]]*[\s,])?(Fact|Theory|Test|TestMethod|DataTestMethod|TestCase|TestCaseSource` +
				`|SkippableFact|SkippableTheory|RetryFact|RetryTheory|UITestMethod|AvaloniaFact)([\],\s(]|$)`,
		),
		Declaration: regexp.MustCompile(`^\s*(\[[^\]]*\]\s*)*(public|private|protected|internal)\s[^=;]*\(`),
		Evidence: evidence(
			category(`[Ii]ntegration`)+`|`+using(`DotNet\.Testcontainers|Testcontainers\.\w+|Respawn|WireMock`),
			category(
				`[Ff]unctional`,
			)+`|WebApplicationFactory|Microsoft\.AspNetCore\.(TestHost|Mvc\.Testing)|(^|[^\w])TestServer\(|`+using(
				`Alba`,
			),
			category(
				`[Ee]2[Ee]|EndToEnd|End-to-[Ee]nd|Acceptance|UI|Ui`,
			)+`|`+using(
				`Microsoft\.Playwright|OpenQA\.Selenium|PuppeteerSharp|Atata|Coypu`,
			),
		),
		Conventions: shared,
	}
}

// dartProfile, for Dart and Flutter: `integration_test/` runs the whole app on a device or an
// emulator, end-to-end whatever its name; widget tests stay with the unit tests, as Flutter's own
// guidance groups them.
func dartProfile(shared []PathConvention) Profile {
	tags := func(names string) string {
		return `@Tags\(\[[^\]]*["'](` + names + `)["']|tags:\s*\[?[^\]]*["'](` + names + `)["']`
	}
	imports := func(packages string) string { return `^\s*import\s+["']package:(` + packages + `)/` }
	return Profile{
		Language: "dart",
		Files:    regexp.MustCompile(`(^|/)(test|integration_test|test_driver)/([^/]+/)*[^/]+_test\.dart$`),
		Exclude:  regexp.MustCompile(`(^|/)(\.dart_tool|build|\.pub-cache)/`),
		Dialect:  DialectLine,
		Cases: regexp.MustCompile(
			`^\s*(test|testWidgets|testGoldens|blocTest|patrolTest|patrolWidgetTest|testWithGame|integrationTest)\s*(<[^>]*>)?\s*\(`,
		),
		Evidence: evidence(
			tags(`integration`)+`|`+imports(`testcontainers`),
			tags(`functional`),
			tags(
				`e2e|acceptance`,
			)+`|`+imports(
				`integration_test|patrol|flutter_driver|appium_driver|webdriver`,
			)+`|IntegrationTestWidgetsFlutterBinding`,
		),
		Paths:       paths(``, ``, `(^|/)(integration_test|test_driver)/`),
		Conventions: shared,
	}
}

// terraformProfile, for `terraform test` and Terratest: each `run` block is a test case with a tier
// of its own, as HashiCorp's testing guidance names them -- one in a file with a `mock_provider` or
// an `override_*` block, or with `command = plan`, touches no real infrastructure and is a unit
// test; any other applies with the real providers and is an integration test. `tests/e2e/` holds
// the apply-time suite this repository runs on a disposable cluster. A Terratest test that applies
// is end-to-end, one that only plans an integration test, one that reads HCL offline a unit test.
func terraformProfile(shared []PathConvention) Profile {
	return Profile{
		Language: "terraform",
		Files:    regexp.MustCompile(`\.tftest\.hcl$|(^|/)tests/terratest/([^/]+/)*[^/]+_test\.go$`),
		Exclude:  regexp.MustCompile(`(^|/)(\.terraform|\.terragrunt-cache|vendor)/`),
		Dialect:  DialectTerraform,
		Run:      regexp.MustCompile(`^\s*run\s+"[^"]*"\s*\{`),
		Plan:     regexp.MustCompile(`^\s*command\s*=\s*plan\b`),
		Mock:     regexp.MustCompile(`^\s*(mock_provider|override_resource|override_data|override_module)\b`),
		GoTest:   regexp.MustCompile(`^func\s+(\([^)]*\)\s*)?Test([^a-z]|$)`),
		Skip:     regexp.MustCompile(`^func\s+TestMain\s*\(`),
		Evidence: evidence(
			`terraform\.(InitAndPlan|Plan|InitAndPlanAndShow|InitAndPlanAndShowWithStruct|PlanExitCode)\w*\(`,
			``,
			`terraform\.(InitAndApply|Apply|ApplyAndIdempotent|InitAndApplyAndIdempotent|TgApplyAll|ApplyAll)\w*\(`,
		),
		Paths:       paths(``, ``, `(^|/)tests/e2e/`),
		Conventions: shared,
	}
}
