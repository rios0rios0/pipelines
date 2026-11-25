package entities

// Request is what a judgement is asked: the target branch the pull request merges into, a commit
// to compare with instead of the merge base, the suites the pipeline names, and whether the caller
// insists on blocking.
type Request struct {
	Target        string
	Base          string
	Languages     []string
	ForceBlocking bool
}

// Base is the commit a pull request is compared with, how it was found, and a warning when it is
// not the merge base it should be.
type Base struct {
	Commit      string
	Description string
	Warning     string
}

// Suite is one language's judgement: the verdict, and how each tree's test files were classified.
type Suite struct {
	Verdict     Verdict
	Target      Classification
	PullRequest Classification
}

// Report is a whole judgement: the two commits, the policy it applied and where it came from, and
// every suite's verdict.
type Report struct {
	Target        string
	Base          Base
	Head          string
	Policy        Policy
	PolicyFound   bool
	PolicyChanged bool
	Blocking      bool
	Suites        []Suite
}

// Worsened are the languages whose pyramid the pull request worsens, in the order judged.
func (r Report) Worsened() []string {
	var worsened []string
	for _, suite := range r.Suites {
		if suite.Verdict.Worsened() {
			worsened = append(worsened, suite.Verdict.Language)
		}
	}
	return worsened
}
