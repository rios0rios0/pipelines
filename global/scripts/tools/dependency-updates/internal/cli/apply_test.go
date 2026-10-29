package cli_test

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"io/fs"
	"maps"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

const (
	api    = "https://api.github.com/repos"
	gitHub = "https://github.com"
)

// digests and commits of the apply scenarios, each one character repeated.
type values struct {
	oldAMD64, oldARM64, oldTG, newAMD64, newARM64, newTG string
	imageOld, imageStill, imageNew                       string
	actionOld, otherSHA, tagObject, commit               string
}

func applyValues() values {
	return values{
		oldAMD64: repeat("1", 64), oldARM64: repeat("2", 64), oldTG: repeat("3", 64),
		newAMD64: repeat("4", 64), newARM64: repeat("5", 64), newTG: repeat("6", 64),
		imageOld: repeat("a", 64), imageStill: repeat("b", 64), imageNew: repeat("c", 64),
		actionOld: repeat("1", 40), otherSHA: repeat("2", 40), tagObject: repeat("7", 40), commit: repeat("8", 40),
	}
}

// applyRepository has one pin of every shape `--apply` rewrites.
func applyRepository(t *testing.T, root string, v values) {
	t.Helper()
	writeFiles(t, root, map[string]string{
		".changes/unreleased/.gitkeep": "",
		"global/scripts/shared/pinned-versions.sh": "#!/usr/bin/env sh\n" +
			"# upstream: github-release example/tool\n# osv: none\n" +
			"# checksums: https://github.com/example/tool/releases/download/v{version}/checksums.txt\n" +
			"TOOL_PINNED_VERSION=\"1.2.3\"\nTOOL_VERSION=\"${TOOL_VERSION:-${TOOL_PINNED_VERSION}}\"\n" +
			"# asset: https://github.com/example/tool/releases/download/v{version}/tool_{version}_linux_amd64.tar.gz\n" +
			"TOOL_SHA256_AMD64=\"" + v.oldAMD64 + "\"\n" +
			"# asset: https://github.com/example/tool/releases/download/v{version}/tool_{version}_linux_arm64.tar.gz\n" +
			"TOOL_SHA256_ARM64=\"" + v.oldARM64 + "\"\n\n" +
			"# upstream: github-release gruntwork-io/terragrunt\n# osv: none\n" +
			"TERRAGRUNT_PINNED_VERSION=\"1.1.4\"\n" +
			"TERRAGRUNT_VERSION=\"${TERRAGRUNT_VERSION:-${TERRAGRUNT_PINNED_VERSION}}\"\n" +
			"# asset: https://github.com/gruntwork-io/terragrunt/releases/download/v{version}/terragrunt_linux_amd64\n" +
			"TERRAGRUNT_SHA256_AMD64=\"" + v.oldTG + "\"\n\n" +
			"# upstream: pypi pdm\nPDM_SPEC=\"${PDM_SPEC:-pdm==2.29.0}\"\n\n" +
			"# upstream: npm wrangler\nWRANGLER_CLI_SPEC=\"${WRANGLER_CLI_SPEC:-wrangler@4}\"\n\n" +
			"# upstream: goproxy golang.org/x/vuln\nGOVULNCHECK_PINNED_VERSION=\"v1.8.0\"\n" +
			"GOVULNCHECK_VERSION=\"${GOVULNCHECK_VERSION:-${GOVULNCHECK_PINNED_VERSION}}\"\n",
		".github/workflows/ci.yaml": "jobs:\n  build:\n    steps:\n" +
			"      - uses: 'someorg/someaction@" + v.actionOld + "' # v3.1.0\n" +
			"      - uses: 'someorg/someaction/sub@" + v.actionOld + "' # v3.1.0\n" +
			"      - uses: 'other/untouched@" + v.otherSHA + "' # v1.0.0\n" +
			"      - run: 'pip install --only-binary :all: \"pdm==2.29.0\"'\n" +
			"      - run: 'go install golang.org/x/vuln/cmd/govulncheck@v1.8.0'\n" +
			"    container:\n      image: 'someimage:1.0@sha256:" + v.imageOld + "'\n",
		"azure/terragrunt.yaml": "steps:\n  - script: |\n      TERRAGRUNT_VERSION=\"1.1.4\"\n" +
			"      TERRAGRUNT_SHA256=\"" + v.oldTG + "\"\n",
		"containers/Dockerfile": "FROM otherimage:2.0@sha256:" + v.imageStill + "\n" +
			"RUN pip install --only-binary :all: \"pdm==2.29.0\"\n",
	})
}

func applyAnswers(v values) map[string]any {
	asset := func(version, arch string) string {
		return gitHub + "/example/tool/releases/download/v" + version +
			"/tool_" + version + "_linux_" + arch + ".tar.gz"
	}
	return map[string]any{
		"osv:*":                                       []any{},
		"github-release:example/tool":                 "v1.3.0",
		"github-release:gruntwork-io/terragrunt":      "v1.1.6",
		"pypi:pdm":                                    "2.29.2",
		"npm:wrangler":                                "5.1.0",
		"goproxy:golang.org/x/vuln":                   "v1.9.0",
		"github-release:someorg/someaction":           "v4.0.0",
		"github-release:other/untouched":              "v1.0.0",
		"image:someimage:1.0@sha256:" + v.imageOld:    "sha256:" + v.imageNew,
		"image:otherimage:2.0@sha256:" + v.imageStill: "sha256:" + v.imageStill,
		// The rebuild fixes one vulnerability and introduces none.
		"scan:someimage:1.0@sha256:" + v.imageOld: map[string]any{"findings": []any{
			map[string]any{
				"package":   "openssl",
				"version":   "3.0.14",
				"ecosystem": "Debian:13",
				"ids":       []any{"CVE-2026-1"},
				"severity":  "HIGH",
			},
		}},
		"scan:someimage:1.0@sha256:" + v.imageNew: map[string]any{"findings": []any{}},
		// An ANNOTATED tag: its ref names a tag object, which names the commit.
		"GET " + api + "/someorg/someaction/git/ref/tags/v4.0.0": map[string]any{
			"object": map[string]any{"type": "tag", "sha": v.tagObject}},
		"GET " + api + "/someorg/someaction/git/tags/" + v.tagObject: map[string]any{
			"object": map[string]any{"type": "commit", "sha": v.commit}},
		"GET " + api + "/someorg/someaction/compare/" + v.actionOld + "..." + v.commit + "?per_page=1": map[string]any{
			"status": "ahead", "ahead_by": 3, "files": []any{map[string]any{}, map[string]any{}}},
		"GET " + api + "/example/tool/releases/tags/v1.2.3": map[string]any{"assets": []any{
			map[string]any{"name": "tool_1.2.3_linux_amd64.tar.gz", "digest": "sha256:" + v.oldAMD64},
			map[string]any{"name": "tool_1.2.3_linux_arm64.tar.gz", "digest": "sha256:" + v.oldARM64}}},
		"GET " + api + "/example/tool/releases/tags/v1.3.0": map[string]any{"assets": []any{
			map[string]any{"name": "tool_1.3.0_linux_amd64.tar.gz", "digest": "sha256:" + v.newAMD64},
			// No recorded digest, as a release published before GitHub recorded any: downloaded and hashed.
			map[string]any{"name": "tool_1.3.0_linux_arm64.tar.gz", "digest": nil}}},
		"SHA256 " + asset("1.3.0", "arm64"): v.newARM64,
		"GET " + gitHub + "/example/tool/releases/download/v1.3.0/checksums.txt": v.newAMD64 +
			"  tool_1.3.0_linux_amd64.tar.gz\n" + v.newARM64 + " *tool_1.3.0_linux_arm64.tar.gz\n",
		"GET " + api + "/gruntwork-io/terragrunt/releases/tags/v1.1.4": map[string]any{"assets": []any{
			map[string]any{"name": "terragrunt_linux_amd64", "digest": "sha256:" + v.oldTG}}},
		"GET " + api + "/gruntwork-io/terragrunt/releases/tags/v1.1.6": map[string]any{"assets": []any{
			map[string]any{"name": "terragrunt_linux_amd64", "digest": "sha256:" + v.newTG}}},
	}
}

type applyRun struct {
	workdir string
	result  outcome
}

func (r applyRun) repo(t *testing.T, path string) string {
	t.Helper()
	return read(t, filepath.Join(r.workdir, "repo", filepath.FromSlash(path)))
}

func (r applyRun) report(t *testing.T, name string) string {
	t.Helper()
	return read(t, filepath.Join(r.workdir, "out", name))
}

func runApply(t *testing.T, edit func(map[string]any, values)) applyRun {
	t.Helper()
	v := applyValues()
	workdir := t.TempDir()
	applyRepository(t, filepath.Join(workdir, "repo"), v)
	answers := applyAnswers(v)
	if edit != nil {
		edit(answers, v)
	}
	writeJSON(t, filepath.Join(workdir, "fixture.json"), answers)
	result := run(t, workdir, "--repo-dir", "repo", "--report", "out", "--fixture", "fixture.json", "--apply",
		"--timestamp", "2026-10-08T06:00:00Z", "--now", "2026-10-10T06:00:00Z")
	return applyRun{workdir: workdir, result: result}
}

func treeDigest(t *testing.T, root string) string {
	t.Helper()
	sums := map[string]string{}
	require.NoError(t, filepath.WalkDir(root, func(path string, entry fs.DirEntry, err error) error {
		if err != nil || entry.IsDir() {
			return err
		}
		content, readErr := os.ReadFile(path)
		relative, relErr := filepath.Rel(root, path)
		sum := sha256.Sum256(content)
		sums[relative] = hex.EncodeToString(sum[:])
		return errors.Join(readErr, relErr)
	}))
	keys := make([]string, 0, len(sums))
	for key := range maps.Keys(sums) {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	var builder strings.Builder
	for _, key := range keys {
		builder.WriteString(key + sums[key] + "\n")
	}
	return builder.String()
}

func TestApplyCommandLine(t *testing.T) {
	t.Parallel()

	t.Run("should rewrite every kind of stale pin and nothing else", func(t *testing.T) {
		t.Parallel()
		// given
		v := applyValues()

		// when
		applied := runApply(t, nil)

		// then
		require.Equal(t, 0, applied.result.exit, applied.result.output())
		workflow := applied.repo(t, ".github/workflows/ci.yaml")
		assert.Contains(t, workflow, "someorg/someaction@"+v.commit+"' # v4.0.0")
		assert.Contains(t, workflow, "someorg/someaction/sub@"+v.commit+"' # v4.0.0")
		assert.NotContains(t, workflow, v.tagObject, "an annotated tag's own object is never pinned")
		assert.Contains(t, workflow, "other/untouched@"+v.otherSHA+"' # v1.0.0")
		assert.Contains(t, workflow, "someimage:1.0@sha256:"+v.imageNew)
		assert.Contains(t, workflow, `"pdm==2.29.2"`)
		assert.Contains(t, workflow, "govulncheck@v1.9.0")
		manifest := applied.repo(t, "global/scripts/shared/pinned-versions.sh")
		assert.Contains(t, manifest, `TOOL_PINNED_VERSION="1.3.0"`)
		assert.Contains(t, manifest, `TOOL_SHA256_AMD64="`+v.newAMD64+`"`)
		assert.Contains(t, manifest, `TOOL_SHA256_ARM64="`+v.newARM64+`"`)
		assert.NotContains(t, manifest, v.oldAMD64)
		assert.Contains(t, manifest, "pdm==2.29.2}")
		assert.Contains(t, manifest, "wrangler@5}")
		assert.Contains(t, manifest, `GOVULNCHECK_PINNED_VERSION="v1.9.0"`)
		assert.Contains(t, applied.repo(t, "azure/terragrunt.yaml"), `TERRAGRUNT_SHA256="`+v.newTG+`"`)
		assert.Contains(t, applied.repo(t, "containers/Dockerfile"), "otherimage:2.0@sha256:"+v.imageStill)
	})

	t.Run("should write the pull request, the changelog fragment and the fingerprint", func(t *testing.T) {
		t.Parallel()
		// given / when
		applied := runApply(t, nil)

		// then
		fingerprint := strings.TrimSpace(applied.report(t, "fingerprint.txt"))
		body := applied.report(t, "pull-request.md")
		assert.Contains(t, body, "<!-- dependency-updates-fingerprint: "+fingerprint+" -->")
		assert.Contains(t, body, "https://github.com/someorg/someaction/releases/tag/v4.0.0")
		assert.Contains(t, body, "**major**")
		assert.Contains(t, body, "SHA-256 of the downloaded asset")
		assert.Contains(t, body, "matching `checksums.txt`")
		assert.Contains(t, body, "3 commits ahead")
		assert.Contains(t, applied.report(t, "pull-request-title.txt"), "bumped 7 pinned dependencies")
		assert.Contains(t, applied.report(t, "commit-message.txt"), "Dependency-Updates-Fingerprint: "+fingerprint)
		fragment := applied.repo(t, ".changes/unreleased/1791439200000000000-"+fingerprint[:4]+".yaml")
		assert.Contains(t, fragment, "kind: 'Changed'")
		assert.Contains(t, fragment, "time: '2026-10-08T06:00:00.000000000Z'")
	})

	t.Run("should produce byte-identical output when run twice from the same start", func(t *testing.T) {
		t.Parallel()
		// given / when
		first, second := runApply(t, nil), runApply(t, nil)

		// then
		assert.Equal(
			t,
			treeDigest(t, filepath.Join(first.workdir, "repo")),
			treeDigest(t, filepath.Join(second.workdir, "repo")),
		)
		assert.Equal(t, first.report(t, "pull-request.md"), second.report(t, "pull-request.md"))
	})

	t.Run("should mark a security fix as one, with its own changelog entry", func(t *testing.T) {
		t.Parallel()
		// given
		vulnerable := func(answers map[string]any, _ values) {
			answers["osv:PyPI:pdm"] = []any{map[string]any{
				"id": "PYSEC-2026-7", "aliases": []any{"CVE-2026-7"},
				"database_specific": map[string]any{"severity": "HIGH"},
				"affected": []any{map[string]any{
					"package": map[string]any{"ecosystem": "PyPI", "name": "pdm"},
					"ranges": []any{map[string]any{"type": "ECOSYSTEM", "events": []any{
						map[string]any{"introduced": "0"}, map[string]any{"fixed": "2.29.1"}}}},
				}},
			}}
		}

		// when
		applied := runApply(t, vulnerable)

		// then
		assert.Equal(t, 1, applied.result.exit, "the scanned branch still runs the vulnerable pin until the fix merges")
		assert.Contains(t, applied.report(t, "pull-request-title.txt"), "fix(deps):")
		assert.Contains(t, applied.report(t, "pull-request-title.txt"), "fixing 1 known vulnerability")
		assert.Contains(t, applied.report(t, "pull-request.md"), "## Security (1 known vulnerability fixed)")
		fingerprint := strings.TrimSpace(applied.report(t, "fingerprint.txt"))
		security := applied.repo(t, ".changes/unreleased/1791439200000000000-"+fingerprint[4:8]+".yaml")
		assert.Contains(t, security, "kind: 'Security'")
		assert.Contains(t, security, "PYSEC-2026-7")
	})
}

func TestApplyCommandLineRefusals(t *testing.T) {
	t.Parallel()

	unbumped := `TOOL_PINNED_VERSION="1.2.3"`
	cases := map[string]struct {
		edit    func(map[string]any, values)
		exit    int
		message string
	}{
		"should refuse a template that no longer locates the committed file": {
			edit: func(answers map[string]any, _ values) {
				answers["GET "+api+"/example/tool/releases/tags/v1.2.3"] = map[string]any{"assets": []any{
					map[string]any{"name": "tool_1.2.3_linux_amd64.tar.gz", "digest": "sha256:" + repeat("9", 64)},
					map[string]any{"name": "tool_1.2.3_linux_arm64.tar.gz", "digest": "sha256:" + repeat("2", 64)}}}
			},
			exit: 1, message: "is not the committed one",
		},
		"should refuse a release that renamed its assets": {
			edit: func(answers map[string]any, v values) {
				answers["GET "+api+"/example/tool/releases/tags/v1.3.0"] = map[string]any{"assets": []any{
					map[string]any{"name": "tool-1.3.0-linux-amd64.tar.gz", "digest": "sha256:" + v.newAMD64}}}
			},
			exit: 1, message: "renamed its assets",
		},
		"should refuse a release that disagrees with its own checksums": {
			edit: func(answers map[string]any, v values) {
				answers["GET "+gitHub+"/example/tool/releases/download/v1.3.0/checksums.txt"] = repeat("e", 64) +
					"  tool_1.3.0_linux_amd64.tar.gz\n" + v.newARM64 + " *tool_1.3.0_linux_arm64.tar.gz\n"
			},
			exit: 1, message: "but the asset itself is",
		},
		"should refuse a version unsafe to write into a sourced shell file": {
			edit: func(answers map[string]any, _ values) {
				answers["github-release:example/tool"] = `v1.3.0";touch_pwned;"`
			},
			exit:    1,
			message: "not safe to write into a sourced shell file",
		},
		"should exit 2 when a lookup fails while applying": {
			edit: func(answers map[string]any, _ values) {
				delete(answers, "GET "+api+"/someorg/someaction/git/ref/tags/v4.0.0")
			},
			exit: 2, message: "no fixture entry",
		},
	}
	for name, scenario := range cases {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			// given / when
			applied := runApply(t, scenario.edit)

			// then
			assert.Equal(t, scenario.exit, applied.result.exit, applied.result.output())
			assert.Contains(t, applied.result.output(), scenario.message)
			if name != "should exit 2 when a lookup fails while applying" {
				assert.Contains(t, applied.repo(t, "global/scripts/shared/pinned-versions.sh"), unbumped)
				assert.NotContains(t, applied.repo(t, "global/scripts/shared/pinned-versions.sh"), "touch_pwned")
			}
		})
	}

	t.Run("should keep a refused name inert in the pull request and the summary", func(t *testing.T) {
		t.Parallel()
		// given
		hostile := func(answers map[string]any, _ values) {
			answers["github-release:example/tool"] = "v1.3.0`|[click](https://example.test)<b>x</b>"
		}

		// when
		applied := runApply(t, hostile)

		// then
		body, summary := applied.report(t, "pull-request.md"), applied.report(t, "dependency-updates.md")
		assert.Contains(t, body, "Not in this pull request")
		assert.NotContains(t, body, "[click](https://example.test)")
		assert.NotContains(t, body, "<b>")
		assert.NotContains(t, summary, "[click](https://example.test)")
	})

	t.Run("should refuse a tag unsafe to write into a workflow", func(t *testing.T) {
		t.Parallel()
		// given
		injected := func(answers map[string]any, _ values) {
			answers["github-release:someorg/someaction"] = "v4.0.0 #injected"
		}

		// when
		applied := runApply(t, injected)

		// then
		assert.Equal(t, 1, applied.result.exit)
		workflow := applied.repo(t, ".github/workflows/ci.yaml")
		assert.NotContains(t, workflow, "injected")
		assert.Contains(t, workflow, "someorg/someaction@"+applyValues().actionOld+"' # v3.1.0")
	})
}

func TestApplyCommandLineGoToolchain(t *testing.T) {
	t.Parallel()

	oldImage := "golang:1.27.1-bookworm@sha256:" + repeat("a", 64)
	newImage := "golang:1.27.2-bookworm@sha256:" + repeat("c", 64)
	goAdvisory := func(identifier, pkg string) map[string]any {
		return map[string]any{"id": identifier, "database_specific": map[string]any{"severity": "HIGH"},
			"affected": []any{map[string]any{
				"package": map[string]any{"ecosystem": "Go", "name": pkg},
				"ranges": []any{map[string]any{"type": "SEMVER", "events": []any{
					map[string]any{"introduced": "0"}, map[string]any{"fixed": "1.27.2"},
				}}},
			}}}
	}
	answers := map[string]any{
		"go-toolchain:golang.org/toolchain": map[string]any{"latest": "1.27.2", "releases": []any{
			map[string]any{"version": "1.27.2", "published": "2026-10-02T20:28:03Z"},
		}},
		"osv:Go:stdlib":                []any{goAdvisory("GO-2026-6603", "stdlib")},
		"osv:Go:toolchain":             []any{goAdvisory("GO-2026-6601", "toolchain")},
		"image:" + oldImage:            "sha256:" + repeat("a", 64),
		"image:golang:1.27.2-bookworm": "sha256:" + repeat("c", 64),
		"scan:" + oldImage:             map[string]any{"findings": []any{}},
		"scan:" + newImage:             map[string]any{"findings": []any{}},
	}

	t.Run("should force Go's fix through its pin, its inputs and its images in one pull request", func(t *testing.T) {
		t.Parallel()
		// given
		workdir := t.TempDir()
		writeFiles(t, filepath.Join(workdir, "repo"), map[string]string{
			".changes/unreleased/.gitkeep": "",
			"global/scripts/shared/pinned-versions.sh": "#!/usr/bin/env sh\n" +
				"# upstream: go-toolchain golang.org/toolchain track=1.27\n# osv: Go stdlib toolchain\n" +
				"GO_PINNED_VERSION=\"1.27.1\"\n",
			".github/workflows/ci.yaml": "jobs:\n  build:\n    steps:\n" +
				"      - with:\n          go-version: '1.27.1'\n" +
				"    container:\n      image: '" + oldImage + "'\n",
			"azure-devops/go.yaml": "steps:\n  - task: 'GoTool@0'\n    inputs:\n      version: '1.27'\n",
		})
		writeJSON(t, filepath.Join(workdir, "fixture.json"), answers)

		// when
		result := run(t, workdir, "--repo-dir", "repo", "--report", "out", "--fixture", "fixture.json", "--apply",
			"--timestamp", "2026-10-08T06:00:00Z", "--now", "2026-10-10T06:00:00Z")

		// then
		assert.Equal(t, 1, result.exit, "the pin in use is vulnerable until the pull request is merged: %s",
			result.output())
		repo := filepath.Join(workdir, "repo")
		assert.Contains(t, read(t, filepath.Join(repo, "global/scripts/shared/pinned-versions.sh")),
			`GO_PINNED_VERSION="1.27.2"`)
		workflow := read(t, filepath.Join(repo, ".github/workflows/ci.yaml"))
		assert.Contains(t, workflow, "go-version: '1.27.2'")
		assert.Contains(t, workflow, "image: '"+newImage+"'")
		assert.Contains(t, read(t, filepath.Join(repo, "azure-devops/go.yaml")), "version: '1.27.2'")
		title := read(t, filepath.Join(workdir, "out", "pull-request-title.txt"))
		assert.True(t, strings.HasPrefix(title, "fix(deps):"), title)
		body := read(t, filepath.Join(workdir, "out", "pull-request.md"))
		assert.Contains(t, body, "`golang:1.27.1-bookworm -> golang:1.27.2-bookworm`")
		assert.Contains(t, body, "GO-2026-6601", "the go command's own advisory is part of the fix")
		assert.Contains(t, result.stdout, "UPDATE  golang:1.27.1-bookworm")
	})
}

func TestApplyCommandLineImageForms(t *testing.T) {
	t.Parallel()

	scanner := "sonarsource/sonar-scanner-cli:12.1.0.3233_8.0.1@sha256:"
	node := "node:18.17.1-bookworm@sha256:"
	// imageForms writes one image the way each platform does -- a scalar under
	// GitHub's `container:` and Azure DevOps' `containers:`, a block and a flow
	// mapping under GitLab CI -- and a second only GitLab CI's mapping names.
	imageForms := func(scannerDigest, nodeDigest string) map[string]string {
		scalar := "jobs:\n  sonarqube:\n    container:\n      image: '" + scanner + scannerDigest + "'\n"
		return map[string]string{
			".changes/unreleased/.gitkeep": "",
			"global/scripts/shared/pinned-versions.sh": "#!/usr/bin/env sh\n" +
				"# upstream: github-release example/binary\n# osv: none\nBINARY_PINNED_VERSION=\"1.2.3\"\n",
			".github/workflows/go.yaml":  scalar,
			".github/workflows/npm.yaml": scalar,
			"azure-devops/sonarqube.yaml": "resources:\n  containers:\n    - container: 'sonar'\n" +
				"      image: '" + scanner + scannerDigest + "'\n",
			"gitlab/abstracts.yaml": ".sonarqube:\n  image:\n    name: '" + scanner + scannerDigest + "'\n" +
				"    entrypoint: ['']\n",
			"gitlab/flow.yaml": ".sonarqube-flow:\n  image: { name: '" + scanner + scannerDigest + "', entrypoint: [''] }\n",
			"gitlab/yarn.yaml": ".yarn:\n  image:\n    name: '" + node + nodeDigest + "'\n" +
				"    docker:\n      user: 'node'\n",
		}
	}

	t.Run("should move every copy of an image with one update, in whichever form each is written", func(t *testing.T) {
		t.Parallel()
		// given
		workdir := t.TempDir()
		before, after := imageForms(repeat("a", 64), repeat("b", 64)), imageForms(repeat("c", 64), repeat("d", 64))
		writeFiles(t, filepath.Join(workdir, "repo"), before)
		clean := map[string]any{"findings": []any{}}
		writeJSON(t, filepath.Join(workdir, "fixture.json"), map[string]any{
			"osv:*":                              []any{},
			"github-release:example/binary":      "v1.2.3",
			"image:" + scanner + repeat("a", 64): "sha256:" + repeat("c", 64),
			"image:" + node + repeat("b", 64):    "sha256:" + repeat("d", 64),
			"scan:" + scanner + repeat("a", 64):  clean,
			"scan:" + "sonarsource/sonar-scanner-cli:12.1.0.3233_8.0.1@sha256:" + repeat("c", 64): clean,
			"scan:" + node + repeat("b", 64): clean,
			"scan:" + node + repeat("d", 64): clean,
		})

		// when
		result := run(t, workdir, "--repo-dir", "repo", "--report", "out", "--fixture", "fixture.json", "--apply",
			"--timestamp", "2026-10-08T06:00:00Z", "--now", "2026-10-10T06:00:00Z")

		// then
		require.Equal(t, 0, result.exit, result.output())
		for path, want := range after {
			if strings.HasSuffix(path, ".yaml") {
				assert.Equal(t, want, read(t, filepath.Join(workdir, "repo", filepath.FromSlash(path))), path)
			}
		}
		assert.Equal(t, 2, strings.Count(result.stdout, "APPLIED"), "one update per image, not one per copy")
		assert.Contains(t, result.stdout, "node:18.17.1-bookworm", "an image only a mapping names is maintained")
	})
}
