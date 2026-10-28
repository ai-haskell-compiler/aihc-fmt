# AGENTS

## Language

Always use ASD-STE100 Simplified Technical English, Issue 9, for all English text.
Obey its writing rules and use its approved dictionary.
Use technical nouns and technical verbs only as ASD-STE100 permits.

This requirement applies to all project communication.
Examples are PR descriptions, chats, documentation, code comments, feedback, and reviews.
It also applies to commit messages, issue text, test descriptions, and user messages.

Use short sentences and give only one instruction in each sentence.
Use a maximum of 20 words in an instruction.
Use a maximum of 25 words in a descriptive sentence.
Use the active voice.
Use the imperative form for instructions.
Use the same word for the same meaning.

Do not use a different word only to make the text varied.
Do not use contractions or semicolons.
Use the `-ing` form of a verb only as an approved technical noun or its modifier.
Put a condition before the action when the reader must know the condition first.
If ASD-STE100 and another writing rule disagree, use ASD-STE100.

## Development Environment

- Use `gh`, `cabal`, `just`, and `nix`.
- Use `nix develop` to get the other tools.
- For a fast local test, use `just test`.
- For a fast check of all items, use `just check`.
- For a slow check in an isolated sandbox, use `nix flake check`.

## The aihc-parser Submodule

The `aihc-parser` directory is a Git submodule.
Cabal and Nix build aihc-parser from this directory.

- Make pretty-printer changes in the aihc-parser repository.
- Open a PR in aihc-parser for each change to the submodule.
- Move the submodule only to a commit that is on the aihc-parser `main` branch.
- In the aihc-fmt PR, give the aihc-parser PR that each submodule change includes.
- Do not change the aihc-parser files only in aihc-fmt.

## Mandatory Post-Push Procedure

Open a PR as soon as possible.

After each push, run `just fmt` and then `just check` locally.

If `just fmt` changes files, commit and push those changes.
Then, run `just fmt` and `just check` again.

If `just check` fails, correct each problem, commit and push the changes, then run both commands again.

## Branch Policy

Do not push to `main`.
Make a feature branch for each change.
Then, open a PR to merge the branch into `main`.

## PR Procedure

- Use the Conventional Commits format for each PR title.
- Write each PR description in ASD-STE100.
- If the branch has an active PR, commit and push all applicable changes.

## Test Rules

### Do

- Each new test must fail without the other changes in the PR.
  Run the test on `main` or with the fix reverted.
  If the test passes before and after, delete it.
- Before you add a test, name the defect it finds.
  No existing test must find that defect.
  If you cannot name one, do not add the test.
- Put the test in the existing harness.
  Formatter cases go in the YAML fixtures in `test/Test/Fixtures/fmt`.
  Do not write a new harness for one test.
- If the defect is in the aihc-parser pretty-printer, add the test to aihc-parser.
- For a bug fix, first reduce the input.
  Find the smallest program that shows the bug.
  Then add that program as the test.
- Test observable results only.
  Examples are diagnostics, golden output, and program output.
- Keep golden output small.
  A golden file that changes on each unrelated optimizer change is too costly.
- A property test must state a property that is not the implementation.
  Say what the generator covers.
- Make each test give the same result on each run.
  Do not depend on wall-clock time, the network, the environment, or map order.
- When a test fails after your change, give a reason in the PR for each changed expectation.
  Do not accept a new golden output without a reason.
- Give the cost of each new test in the PR.
  The cost is run time, flakiness, and the number of unrelated changes that will break it.

### Do Not

- Do not add tests to a refactor PR.
  If the behavior is the same, the existing tests are the proof.
  An empty test diff is the evidence that the PR is a refactor.
- Do not test what the type checker already proves.
  A test that a bad program gives a diagnostic is correct.
  A test that a well-typed value has a type is not.
- Do not test trivial code.
  Examples are getters, constants, Show instances, and derived instances.
- Do not compute the expected value with the function under test.
  That test cannot fail.
- Do not use mocks.
  The formatter is pure.
  Run the real formatter.
- Do not add timing tests.
  They are fragile.
  If performance is the subject, measure allocation or instruction counts.
  As an alternative, report the numbers in the PR and add no test.
- Do not skip, weaken, or delete a failing test to make CI green.
- Do not assert on internal data structures.
  A refactor can change them without a change in behavior.
- Do not use test coverage as a goal.
- Do not put test-only code in the `aihc-fmt` library.
  Put it in the test suite.

## Property Test Generators

A property test must hold for all values.
Thus, make each generator as general as possible.

- Generate arbitrary values.
- Do not add artificial structure to a generator.
- Do not limit a generator to values that easily satisfy the property.
- Do not add a generator rule only to find one known defect.
- For one known defect, write an explicit test with that value.
- A generator can leave out values that the input domain does not allow.
  For example, a generator can leave out a variable name that is a reserved keyword.
- If a generator leaves out values, write the reason in a comment.

## Commits

Use the Conventional Commits format:

```text
<type>[optional scope]: <description>
```

Use one of these types:
`feat`, `fix`, `docs`, `style`, `refactor`, `perf`, `test`, `build`, `ci`, or `chore`.

Examples:

```text
feat: add user authentication
fix(auth): correct null pointer in login
docs: update installation guide
```

Write each commit message in ASD-STE100.
