<!--
Copyright 2026 Carlos Eduardo Arango Gutierrez
SPDX-License-Identifier: Apache-2.0

One concern per pull request. Two unrelated fixes are two pull requests.
CONTRIBUTING.md has the build, test, signing and commit rules.
-->

## Problem

<!-- What is broken or missing today. Not the fix — the problem. -->

## Approach

<!--
How this change solves it, and why this way rather than the obvious
alternative. The diff already shows what changed; say why.
-->

## Testing done

<!--
Paste the real output. A claim without output is not evidence.

    swift build
    swift build -c release
    swift test

For a change to power behaviour, add the manual check you ran, for example
`pmset -g assertions` while the app held the assertion.
-->

```
```

## Breaking changes

<!--
None, or list each one with the migration. A change to a public type in
CoffeeBarCore is a breaking change: the library is a published product in
Package.swift.
-->

None.

## Checklist

- [ ] One concern only.
- [ ] Tests came first, and each new test failed before the implementation existed.
- [ ] Test files are named `<Subject>_test.swift`. CONTRIBUTING.md says why.
- [ ] Every commit is signed off and signed: `git commit -s -S`.
- [ ] Commit subjects use `type(scope): description`.
- [ ] No new network call, and no code that reads an agent transcript. Both are non-goals.
- [ ] Docs updated when behaviour changed.

Closes #N
