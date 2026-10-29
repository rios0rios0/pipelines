package main

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestUnguarded(t *testing.T) {
	t.Parallel()

	t.Run("should call every canary by its known verdict when the classifier reads it", func(t *testing.T) {
		t.Parallel()
		// given
		canaries := cancelCanaries()

		// when
		var misread []string
		for _, canary := range canaries {
			if (len(unguarded(canary.expression)) == 0) != canary.safe {
				misread = append(misread, canary.expression)
			}
		}

		// then
		assert.Empty(t, misread)
	})

	t.Run("should name the clause that can start when only one of two carries a guard", func(t *testing.T) {
		t.Parallel()
		// given
		condition := "(!cancelled() && a) || (failure() && b) || (!failure() && c)"

		// when
		clauses := unguarded(condition)

		// then
		assert.Equal(t, []string{"!failure() && c"}, clauses)
	})
}

func TestTopLevelSplitting(t *testing.T) {
	t.Parallel()

	t.Run("should split only where the operator sits outside quotes and parentheses", func(t *testing.T) {
		t.Parallel()
		// given
		expression := "a && (b && c) && contains(x, 'd && e') && f"

		// when
		parts := splitTop(expression, "&&")

		// then
		assert.Equal(t, []string{"a", "(b && c)", "contains(x, 'd && e')", "f"}, parts)
	})

	t.Run("should unwrap only parentheses that enclose the whole term", func(t *testing.T) {
		t.Parallel()
		// given
		wrapped, adjacent := " ((a || b)) ", "(a) && (b)"

		// when
		unwrapped, kept := stripParens(wrapped), stripParens(adjacent)

		// then
		assert.Equal(t, "a || b", unwrapped)
		assert.Equal(t, "(a) && (b)", kept)
	})

	t.Run("should keep the negation outside the parentheses it negates", func(t *testing.T) {
		t.Parallel()
		// given
		term := "! ( Cancelled( ) )"

		// when
		got := canonical(term)

		// then
		assert.Equal(t, "!cancelled()", got)
	})

	t.Run("should find a status function only where it starts a word", func(t *testing.T) {
		t.Parallel()
		// given
		called, embedded := "!Failure ( )", "xfailure()"

		// when
		calledStatus, embeddedStatus := callsStatus(called), callsStatus(embedded)

		// then
		assert.True(t, calledStatus)
		assert.False(t, embeddedStatus)
	})
}

func TestOrClauses(t *testing.T) {
	t.Parallel()

	t.Run("should split at depth zero and keep the clauses' own parentheses", func(t *testing.T) {
		t.Parallel()
		// given
		expression := "(a || b) || ( c ) ||"

		// when
		clauses := orClauses(expression)

		// then
		assert.Equal(t, []string{"(a || b)", "( c )"}, clauses)
	})
}

func TestAssociationsOf(t *testing.T) {
	t.Parallel()

	cases := map[string]struct {
		raw, want string
	}{
		"should sort the names when the list holds only strings":  {`["OWNER", "MEMBER"]`, "['MEMBER', 'OWNER']"},
		"should sort the values when the list holds only numbers": {`[2, 1.0, 1]`, "[1.0, 1, 2]"},
		"should keep the order when the list mixes kinds":         {`["b", 1, "a"]`, "['b', 1, 'a']"},
		"should read nested values when an entry is a list":       {`[["x"], null, true]`, "[['x'], None, True]"},
	}
	for name, values := range cases {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			// given
			raw := values.raw

			// when
			allowed, err := associationsOf(raw)

			// then
			require.NoError(t, err)
			assert.Equal(t, values.want, allowed.repr())
		})
	}

	t.Run("should refuse text after the list when one JSON value is expected", func(t *testing.T) {
		t.Parallel()
		// given
		raw := `["OWNER"]]`

		// when
		_, err := associationsOf(raw)

		// then
		require.Error(t, err)
	})
}

func TestSentences(t *testing.T) {
	t.Parallel()

	t.Run("should end a sentence at a full stop or a semicolon when a space follows", func(t *testing.T) {
		t.Parallel()
		// given
		prompt := "Tools: `git add`.\nDenied on purpose: `go`;   `node`.\n\nVersion 1.2 is fine."

		// when
		found := sentences(prompt)

		// then
		assert.Equal(
			t,
			[]string{"Tools: `git add`.", "Denied on purpose: `go`;", "`node`.", "Version 1.2 is fine."},
			found,
		)
	})
}

func TestIsDenial(t *testing.T) {
	t.Parallel()

	cases := map[string]struct {
		sentence string
		want     bool
	}{
		"should read a denial when the sentence says a tool is not granted": {"`gh` is not granted", true},
		"should read a denial in any case when the phrase is capitalised":   {"DENIED: `go`", true},
		"should not read a denial when the phrase is part of a longer word": {"This is notable", false},
		"should not read a denial when the word is only a prefix":           {"undenied access", false},
		"should not read a denial when a pipe is described as refused":      {"a pipe is refused as a whole", false},
	}
	for name, values := range cases {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			// given
			sentence := values.sentence

			// when
			got := isDenial(sentence)

			// then
			assert.Equal(t, values.want, got)
		})
	}
}

func TestCommandWord(t *testing.T) {
	t.Parallel()

	cases := map[string]struct{ rule, want string }{
		"should take the binary when the rule names a subcommand": {"git add:*", "git"},
		"should take the binary when the rule names only one":     {"gh:*", "gh"},
		"should trim the space when the rule is padded":           {"  pwd :x", "pwd"},
		"should give nothing when the rule names no command":      {" :*", ""},
	}
	for name, values := range cases {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			// given
			rule := values.rule

			// when
			got := commandWord(rule)

			// then
			assert.Equal(t, values.want, got)
		})
	}

	t.Run("should let a broader grant cover a narrower denial and not the reverse", func(t *testing.T) {
		t.Parallel()
		// given
		broad, narrow := "git", "git add"

		// when
		broadCovers, narrowCovers := covers(broad, "git diff"), covers(narrow, "git diff")

		// then
		assert.True(t, broadCovers)
		assert.False(t, narrowCovers)
	})
}
