<!--
Copyright 2026 Carlos Eduardo Arango Gutierrez
SPDX-License-Identifier: Apache-2.0
-->

# Legal Surface Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the Apache-2.0 text inside the app bundle, and tell a person who installs the DMG what coffee-bar does, what it does not do, and where to report a bug.

**Architecture:** Five independent tasks across three surfaces. The app bundle gains the licence file and a copyright key. The site gains two footer-linked pages, guarded by a new byte-identity check on the footer. The panel gains one caption line. The README and `SECURITY.md` gain the sentences they lack. No task depends on a later task's code.

**Tech Stack:** Bash (`scripts/build-app.sh`), Swift 6 with swift-testing (`@Test`, `#expect`), hand-written HTML and CSS with no build step.

**Spec:** `docs/superpowers/specs/2026-08-05-coffee-bar-legal-surface-design.md`

## Global Constraints

Every task's requirements implicitly include this section.

- **Base commit:** cut from `389f10e`. Re-verify every fact in spec §2 before writing copy, and report any delta rather than working around it.
- **Signed commits.** Every commit uses `git commit -s -S`. Both flags. `-s` writes the DCO sign-off for Carlos Eduardo Arango Gutierrez from the repository's configured git identity; do not type the address by hand.

  > **Do not write the author's username into any tracked file.**
  > `FixtureRedaction_test.swift` defines `forbiddenUsername` and
  > `noTrackedFileCarriesLiveSessionProse` scans every tracked file for it,
  > exempting exactly one path — its own. The guard exists because 599
  > characters of live session text once reached a public repository.
  >
  > An earlier version of THIS line spelled the address out and turned the suite
  > red at `bee1336`. Commit messages are not scanned, so `git commit -s` is
  > safe. Never add a second exempt path to that guard.
- **SPDX header** on every new file: `Copyright 2026 Carlos Eduardo Arango Gutierrez` and `SPDX-License-Identifier: Apache-2.0`, in that file type's comment syntax.
- **The year is 2026.** Never copy a year from an existing file.
- **No external requests from the site.** No web font, no analytics, no CDN, no tracking script. Every page's head comment already promises this.
- **Numbers in site prose must be real product constants.** Six parameterised guards in `DocsClaims_test.swift` sweep every discovered page under `site/`. A number invented for readability turns the suite red.
- **Swift 6.** `Package.swift` declares `swift-tools-version 6.0` and `.swiftLanguageMode(.v6)`. Minimum macOS is 14.0.
- **Never weaken a guard to make a page pass.** If a new page fails `everyPageCarriesTheSameSidebar()`, the page is wrong.
- **A filtered test run must print a NON-ZERO count, or it verified nothing.**

  > `swift test --filter <X>` returns **rc=0** when it matches nothing, printing
  > `Test run with 0 tests`. That is a vacuous pass and it reads as green. Always
  > quote the printed count. Treat `0 tests` as a FAILED verification.
  >
  > Filter on test NAMES, with a regex for several, so that renaming a test file
  > cannot silently empty a run.
  >
  > **A claim that was tested and found false, recorded so nobody re-adds it.**
  > legal-t4 reported that filtering on a test FILE name matches only while
  > SwiftPM recompiles, and returns 0 tests on a no-op build. That is NOT
  > reproducible. Measured on 2026-08-05, twice each, second run a no-op:
  >
  > ```
  > swift test --filter DocsClaims      -> 11 tests, both runs
  > swift test --filter PanelLegalLine  ->  4 tests, both runs
  > ```
  >
  > SwiftPM matches the source file name consistently. The count rule above
  > stands on its own merits; the mechanism legal-t4 gave for it does not.
  >
  > Filter on test NAMES, with a regex when you need several. Always quote the
  > printed count. Treat `0 tests` as a FAILED verification, never as a pass.
- **Do not push.** Do not open a PR. Do not comment on an issue. Leave every commit local and report.
- **Work only in** `.worktrees/legal-surface` on branch `docs/legal-surface`. Never commit from the root checkout or from another worktree.

## File Structure

| File | Responsibility | Task |
|---|---|---|
| `scripts/build-app.sh` | copies `LICENSE` into the bundle; writes `NSHumanReadableCopyright` | 1 |
| `Tests/CoffeeBarCoreTests/BundleLicence_test.swift` | proves the licence the script copies is real and Apache-2.0 | 1 |
| `Tests/CoffeeBarCoreTests/SiteClaims_test.swift` | gains guard 4c, the footer byte-identity check | 2 |
| `site/terms.html` | what it does, what it does not do, no warranty, bug route | 3 |
| `site/privacy.html` | what it reads, what it never reads, what leaves the Mac | 3 |
| `site/index.html`, `install.html`, `docs.html`, `changelog.html` | footer gains two links | 3 |
| `Sources/CoffeeBarUI/PanelView.swift` | one caption line naming the licence | 4 |
| `Tests/CoffeeBarUITests/PanelLegalLine_test.swift` | pins the panel line to the shipped licence | 4 |
| `README.md` | non-endorsement sentence, no-warranty note, bug route | 5 |
| `SECURITY.md` | eternal claim becomes a versioned commitment | 5 |

Task order matters in one place only: task 2 lands the footer guard **before** task 3 edits six footers. Everything else is independent.

---

### Task 1: Ship the licence inside the bundle

Closes gap G1, the only compliance defect. Apache-2.0 §4(a) requires giving recipients a copy of the Licence, and the DMG currently ships none.

**Files:**
- Modify: `scripts/build-app.sh`
- Create: `Tests/CoffeeBarCoreTests/BundleLicence_test.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `build/CoffeeBar.app/Contents/Resources/LICENSE`, and the `NSHumanReadableCopyright` key in the bundle's `Info.plist`. No later task reads either.

- [ ] **Step 1: Write the failing test**

Create `Tests/CoffeeBarCoreTests/BundleLicence_test.swift`:

```swift
// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Testing
import Foundation

/// Guards the PRECONDITION of the bundle copy, not the copy itself.
///
/// **What this cannot do, stated so nobody over-trusts it.** It does not run
/// `scripts/build-app.sh` and it never looks inside a built bundle. Running a
/// release build inside the unit suite would add minutes to every run for one
/// assertion. The runtime check lives in the script, where it aborts the build,
/// and the acceptance step for this task is a real build with pasted output.
///
/// What it DOES catch is the failure that would make the script's own check
/// vacuous: `LICENSE` going missing, being emptied, or being replaced by a
/// different licence while the panel and the site still say Apache-2.0.

private var packageRoot: URL {
    URL(fileURLWithPath: #filePath)     // …/Tests/CoffeeBarCoreTests/BundleLicence_test.swift
        .deletingLastPathComponent()    // …/Tests/CoffeeBarCoreTests
        .deletingLastPathComponent()    // …/Tests
        .deletingLastPathComponent()    // the package root
}

@Test func theRepositoryShipsTheLicenceTheBundleCopyDependsOn() throws {
    // Named bug: `build-app.sh` copies a file that is missing or empty, and the
    // DMG ships with no licence while every surface claims Apache-2.0.
    let licence = try String(contentsOf: packageRoot.appending(path: "LICENSE"),
                             encoding: .utf8)
    #expect(licence.contains("Apache License"),
            "LICENSE does not name the Apache License; the bundle copy would ship the wrong text")
    #expect(licence.contains("Version 2.0"),
            "LICENSE does not name Version 2.0; the bundle copy would ship the wrong version")
    #expect(licence.count > 10_000,
            "LICENSE is \(licence.count) bytes; the full Apache-2.0 text is about 11kB, so this file is truncated")
}

@Test func theBuildScriptCopiesTheLicenceAndChecksItArrived() throws {
    // Named bug: the copy line is removed in a refactor, or is written without
    // the arrival check, so a failed `cp` leaves a bundle with no licence and
    // the script still exits 0. `rules/shell-conventions.md` records that `cp`
    // returns 0 while doing nothing useful.
    let script = try String(contentsOf: packageRoot.appending(path: "scripts/build-app.sh"),
                            encoding: .utf8)
    #expect(script.contains("${REPO_ROOT}/LICENSE"),
            "build-app.sh no longer reads LICENSE from the repository root")
    #expect(script.contains("${CONTENTS}/Resources/LICENSE"),
            "build-app.sh no longer writes LICENSE into the bundle")
    #expect(script.contains("[ -s \"${CONTENTS}/Resources/LICENSE\" ]"),
            "build-app.sh copies LICENSE without checking it arrived and is non-empty")
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter "theRepositoryShipsTheLicence|theBuildScriptCopiesTheLicence"`

Expected: `theRepositoryShipsTheLicenceTheBundleCopyDependsOn` PASSES (the repo already has a good `LICENSE`). `theBuildScriptCopiesTheLicenceAndChecksItArrived` FAILS on all three expectations, because `build-app.sh` names `LICENSE` nowhere.

A test that passes on its first run is the sign the constitution warns about. Confirm the second test really is red before continuing.

- [ ] **Step 3: Add the copy to the build script**

In `scripts/build-app.sh`, immediately after the glyph block ends (after the line `echo "    ${glyph_count} glyph files copied"`) and before the `# --- Info.plist ---` banner, insert:

```sh
# --- licence -----------------------------------------------------------------
#
# Apache-2.0 section 4(a) requires giving every recipient of the Work a copy of
# the Licence. The DMG is a distribution of the Work in Object form, so the
# licence travels inside the bundle rather than only in the repository.
#
# `-s` and not `-f`: an empty file satisfies `-f` and complies with nothing.
command cp -f "${REPO_ROOT}/LICENSE" "${CONTENTS}/Resources/LICENSE"
[ -s "${CONTENTS}/Resources/LICENSE" ] \
    || die "LICENSE did not land in the bundle"
echo "    LICENSE copied ($(wc -c < "${CONTENTS}/Resources/LICENSE" | tr -d ' ') bytes)"
```

The variable is `REPO_ROOT`. The script defines `SCRIPT_DIR`, `REPO_ROOT`, `PRODUCT`, `APP_NAME`, `BUNDLE_ID`, `OUT_DIR`, `APP`, `CONTENTS` and `ART`. There is no `ROOT`.

- [ ] **Step 4: Add the copyright key to Info.plist**

In the same file, inside the `Info.plist` heredoc, directly after the `CFBundleVersion` pair and before `LSMinimumSystemVersion`, insert:

```xml
    <key>NSHumanReadableCopyright</key>
    <string>Copyright 2026 Carlos Eduardo Arango Gutierrez. Apache-2.0. A personal project, not an NVIDIA product.</string>
```

macOS reads this key for the standard About panel and for Finder's Get Info, so the disclaimer travels inside the signed artifact.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --filter "theRepositoryShipsTheLicence|theBuildScriptCopiesTheLicence"`

Expected: both tests PASS.

- [ ] **Step 6: Build the app for real and prove the licence arrived**

Run each command and keep the output for the report:

```bash
scripts/build-app.sh
ls -l build/CoffeeBar.app/Contents/Resources/LICENSE
plutil -extract NSHumanReadableCopyright raw -o - build/CoffeeBar.app/Contents/Info.plist
plutil -lint build/CoffeeBar.app/Contents/Info.plist
```

Expected: a non-empty `LICENSE` of about 11kB; the copyright string printed verbatim; `Info.plist: OK`.

This step is the real gate for this task. The Swift tests check the precondition and the script text; only this run proves a bundle carries the file.

- [ ] **Step 7: Run the whole suite**

Run: `swift test`

Expected: rc=0. Record the test count. The ledger recorded 573 tests at `389f10e`; report the number you actually see and note any difference.

- [ ] **Step 8: Commit**

```bash
git add scripts/build-app.sh Tests/CoffeeBarCoreTests/BundleLicence_test.swift
git commit -s -S -m "fix(build): ship the Apache-2.0 text inside the app bundle

Apache-2.0 section 4(a) requires giving every recipient of the Work a copy
of the Licence. The DMG distributes the Work in Object form and carried no
licence at all: build-app.sh copied the binary and the menu-bar glyphs and
nothing else. That is a compliance gap against the project's own licence.

The bundle now carries LICENSE in Resources, with the arrival check the
glyph block already uses, because cp returns 0 while doing nothing useful.
Info.plist gains NSHumanReadableCopyright, which macOS shows in Get Info
and in the standard About panel, so the non-endorsement sentence travels
inside the signed artifact rather than only on the website.

The new test guards the precondition, not the copy. It does not run a
release build inside the unit suite; the script's own check aborts the
build, and the task's acceptance is a real build with pasted output."
```

---

### Task 2: Guard the footer against drift

Closes gap G7. Task 3 edits six footers by hand. This guard must exist first, so the edit is made against a check rather than against hope.

**Files:**
- Modify: `Tests/CoffeeBarCoreTests/SiteClaims_test.swift`

**Interfaces:**
- Consumes: `discoveredSitePages()`, `surfaceText(_:)`, `matches(_:in:)` from `DocsClaims_test.swift`; `firstDifference(_:_:)`, which is `private` inside `SiteClaims_test.swift`.
- Produces: `everyPageCarriesTheSameFooter()`. Task 3 must keep it green.

The guard lives in `SiteClaims_test.swift` and nowhere else, because `firstDifference` is private to that file.

- [ ] **Step 1: Write the failing test**

Append to `Tests/CoffeeBarCoreTests/SiteClaims_test.swift`:

```swift
// MARK: - Guard 4c: the duplicated footer cannot drift

/// The footer is byte-identical on every page.
///
/// Guard 4a makes this argument for the sidebar. The footer has the same shape
/// and the same failure: no build step, no template, one copy per page edited by
/// hand. It went unguarded until the terms and privacy pages took the count from
/// four footers to six.
///
/// Unlike the sidebar, nothing is stripped before comparing. The footer carries
/// no per-page attribute, so every byte must match.
///
/// **What this cannot do.** It proves the six footers agree. It does not prove
/// they are right. Six identical footers all linking to a deleted page pass.
@Test func everyPageCarriesTheSameFooter() throws {
    let pages = discoveredSitePages()
    #expect(pages.count >= 4,
            "discovery found \(pages.count) page(s) under site/; comparing fewer than two footers proves nothing")

    var footers: [(page: String, block: String)] = []
    for page in pages {
        let found = try matches("<footer[\\s\\S]*?</footer>", in: try surfaceText(page))
        #expect(found.count == 1,
                "\(page) has \(found.count) footer blocks; every page carries exactly one")
        guard let block = found.first?[0] else { continue }
        footers.append((page, block))
    }

    #expect(footers.count == pages.count,
            "read a footer from \(footers.count) of \(pages.count) pages; a page with no footer is a page this guard skipped")

    guard let reference = footers.first else { return }
    for entry in footers.dropFirst() {
        #expect(entry.block == reference.block,
                "the footer on \(entry.page) differs from the one on \(reference.page). First difference, \(reference.page) then \(entry.page), \(firstDifference(reference.block, entry.block))")
    }
}
```

- [ ] **Step 2: Run it and watch it pass, then prove it discriminates**

Run: `swift test --filter everyPageCarriesTheSameFooter`

Expected: PASS. The four current footers are already byte-identical, so a green first run is correct here and is not the theater-test smell.

A guard that has never gone red proves nothing. Mutate one footer and confirm the guard catches it:

```bash
cp site/docs.html /tmp/docs.html.bak
perl -0pi -e 's{Built by <a href="https://github\.com/ArangoGutierrez">}{Built by <a href="https://github.com/arangogutierrez">}' site/docs.html
diff /tmp/docs.html.bak site/docs.html
```

`diff` must print exactly one changed line. If it prints nothing, the substitution silently did nothing — fix the pattern before continuing, and do not accept a vacuous run.

- [ ] **Step 3: Run the guard against the mutant**

Run: `swift test --filter everyPageCarriesTheSameFooter`

Expected: FAIL, naming `site/docs.html` and printing the first differing line.

- [ ] **Step 4: Restore the file and confirm green**

```bash
command cp -f /tmp/docs.html.bak site/docs.html
diff /tmp/docs.html.bak site/docs.html && echo "restored clean"
swift test --filter everyPageCarriesTheSameFooter
```

Expected: `restored clean`, then PASS. Keep the red and green outputs for the report; a guard shipped without a demonstrated red is a guard nobody has tested.

- [ ] **Step 5: Run the whole suite**

Run: `swift test`

Expected: rc=0, one more test than task 1 recorded.

- [ ] **Step 6: Commit**

```bash
git add Tests/CoffeeBarCoreTests/SiteClaims_test.swift
git commit -s -S -m "test(site): guard the footer against drift the way the sidebar is guarded

The sidebar has guard 4a because it is copied by hand into every page with
no build step and no template. The footer has exactly the same shape and
exactly the same failure, and had no guard at all.

The terms and privacy pages take the site from four footers to six, and
those two footers also carry the only links to the new pages. Landing this
check first means that edit is made against a guard rather than against
hope.

Nothing is stripped before comparing, unlike 4a: the footer carries no
per-page attribute, so every byte must match. The guard was mutation-checked
before this commit - one footer altered by hand turned it red and naming the
page, and restoring the file turned it green."
```

---

### Task 3: The terms and privacy pages

Closes gap G5. Two new pages, footer-linked, out of the sidebar.

**Files:**
- Create: `site/terms.html`
- Create: `site/privacy.html`
- Modify: `site/index.html`, `site/install.html`, `site/docs.html`, `site/changelog.html`

**Interfaces:**
- Consumes: `everyPageCarriesTheSameFooter()` from task 2.
- Produces: `terms.html`, which task 4's panel line links to. The published URL is `https://arangogutierrez.github.io/coffee-bar/terms.html`.

**Read before writing a single sentence.** Every page under `site/` is swept by six parameterised prose guards in `DocsClaims_test.swift` and by the structure guards in `SiteClaims_test.swift`. That means:

- Copy the `<nav class="sidebar">` block **verbatim** from `site/index.html`, then delete the ` aria-current="page"` attribute. Neither new page is in the sidebar, so no entry is current. Guard 4a strips that attribute before comparing, so the block still matches.
- Copy the `<p class="sidebar-version">` line verbatim. It must name `v0.1.1`.
- Every number in the prose must be a real product constant. The safest copy for these two pages contains no numbers at all except the version stamp.

- [ ] **Step 1: Create `site/terms.html`**

Build the file from `site/index.html`'s skeleton: the `<!DOCTYPE html>` line, the SPDX comment, `<html lang="en">`, the `<head>` block with the title, description and canonical URL changed for this page, `<body>`, `<div class="shell">`, the sidebar, `<div class="wrap">`, the content below, then the footer from step 3, and the closing tags.

The canonical URL is `https://arangogutierrez.github.io/coffee-bar/terms.html`. The title is `Terms — coffee-bar`.

The content:

```html
<h1>Terms</h1>

<p>coffee-bar is free software under the Apache&nbsp;2.0 Licence. This page says
in plain English what that means for you. The Licence is the text that binds;
this page explains it.</p>

<h2 class="eyebrow">What coffee-bar does</h2>
<p>It holds a sleep assertion while a coding agent is working, so your Mac stays
awake. It releases that assertion when every agent is waiting on a human. It
holds no display assertion by default, so your screen still sleeps on its normal
schedule.</p>

<h2 class="eyebrow">What coffee-bar does not do</h2>
<ul>
  <li>It does not save, back up, or recover your work.</li>
  <li>It does not guarantee your Mac stays awake. macOS, another application, or
      an administrator policy can sleep the machine whatever coffee-bar asks.</li>
  <li>It does not keep the Mac awake with the lid closed. That needs a
      privileged helper, and this release does not have one.</li>
  <li>It does not read your agent conversations.</li>
  <li>It does not change what your agent does, and it never answers a prompt
      for you.</li>
</ul>

<h2 class="eyebrow">No warranty</h2>
<p>coffee-bar is provided as is, with no warranty of any kind. If it fails to
hold your Mac awake, or holds it awake when you did not want it to, you carry
that outcome. The binding text is the Apache&nbsp;2.0 Licence, sections 7 and 8.
A copy of the Licence ships inside the app and lives in
<a href="https://github.com/ArangoGutierrez/coffee-bar/blob/main/LICENSE">the
repository</a>.</p>

<h2 class="eyebrow">Who makes it</h2>
<p>coffee-bar is a personal project by Carlos Eduardo Arango Gutierrez, released
under Apache&nbsp;2.0. It is not an NVIDIA product. NVIDIA does not endorse,
support, or warrant it.</p>

<h2 class="eyebrow">Report a bug</h2>
<p>Open an issue at
<a href="https://github.com/ArangoGutierrez/coffee-bar/issues/new">the issue
tracker</a>. Include the version shown at the bottom of the panel, your macOS
version, what you expected, and what happened instead.</p>

<p class="stamp">This page describes v0.1.1.</p>
```

- [ ] **Step 2: Create `site/privacy.html`**

Same skeleton. Canonical URL `https://arangogutierrez.github.io/coffee-bar/privacy.html`. Title `Privacy — coffee-bar`.

```html
<h1>Privacy</h1>

<p>coffee-bar has no account, no sign-in, and no server. This page says what it
reads on your Mac and what leaves it.</p>

<h2 class="eyebrow">What it reads</h2>
<p>It reads agent session metadata, delivered by hooks you install yourself over
a local socket. It reads three local configuration files to find an OTLP
endpoint you have already configured. It reads nothing else.</p>

<h2 class="eyebrow">What it never reads</h2>
<p>It never reads the contents of your agent conversations. The fields that
carry them are discarded where the event is decoded, before anything stores or
displays it. A test in the suite fails if that ever changes.</p>

<h2 class="eyebrow">What leaves your Mac</h2>
<p>Nothing. There is no telemetry, no analytics, no crash reporting, and no
update ping. The one socket coffee-bar opens is a unix domain socket, which
lives in the filesystem and has no address, no port, and no route off this
machine.</p>

<h2 class="eyebrow">What may change, named in advance</h2>
<p>A future release adds a check for updates. That check will be the first
request coffee-bar makes that leaves your Mac. When it ships, this page will say
what it sends before the release goes out. Any further outbound request will be
opt-in, off by default, and named here first.</p>

<h2 class="eyebrow">Downloading is a separate thing</h2>
<p>Getting coffee-bar is a normal web request. GitHub serves the download and
counts it, as it does for every file it hosts. That is GitHub's logging, under
GitHub's privacy policy, and it happens before coffee-bar ever runs. The app
itself sends nothing.</p>

<p class="stamp">This page describes v0.1.1.</p>
```

- [ ] **Step 3: Replace the footer on all six pages**

The new footer, byte-identical everywhere:

```html
<footer>
<p>Apache-2.0 · <a href="terms.html">Terms</a> · <a href="privacy.html">Privacy</a> · <a href="https://github.com/ArangoGutierrez/coffee-bar/issues/new">Report a bug</a><br>
<a href="https://github.com/ArangoGutierrez/coffee-bar">Source on GitHub</a><br>
Built by <a href="https://github.com/ArangoGutierrez">Carlos Eduardo Arango Gutierrez</a>.</p>
<p class="tm">Apple, macOS and Apple silicon are trademarks of Apple Inc., registered in the U.S. and other countries. coffee-bar is not affiliated with, endorsed by, or sponsored by Apple Inc. or NVIDIA Corporation.</p>
</footer>
```

The trademark paragraph is unchanged. Do not reword it.

Apply it to `index.html`, `install.html`, `docs.html`, `changelog.html`, and use the same block in the two new pages.

- [ ] **Step 4: Add the one new CSS class**

The class vocabulary was measured before this plan was written, so use it as given rather than inventing names:

- `.eyebrow` is the house class for a section heading. Both pages use it, as `site/docs.html` does.
- `.tm` exists, at `site/assets/site.css:343`, and styles the trademark paragraph in the footer.
- **`.lede` does not exist.** An earlier draft of this plan used it. Lead paragraphs on these pages are plain `<p>`.
- `.stamp` does not exist and must be added.

Confirm before editing:

```bash
grep -nE "^\.stamp|^\.lede" site/assets/site.css ; echo "rc=$? (1 = both absent, as expected)"
```

Add exactly this rule at the end of `site/assets/site.css`:

```css
/* The version a legal page describes. Small and quiet: it is a provenance
   note, not a heading, and it must not compete with the text above it. */
.stamp {
  font-size: 0.85rem;
  opacity: 0.7;
  margin-top: 2rem;
}
```

Do not invent other new classes. Every other element on these two pages reuses what the four existing pages already style.

- [ ] **Step 5: Run the structure guards**

Run: `swift test --filter SiteClaims`

Expected: PASS. If `everyPageCarriesTheSameSidebar()` fails, the sidebar was retyped instead of copied — copy it again from `site/index.html` and delete only ` aria-current="page"`. If `everyPageCarriesTheSameFooter()` fails, read the first-difference line it prints; it names the page and the line.

- [ ] **Step 6: Run the prose guards**

Run: `swift test --filter DocsClaims`

Expected: PASS. A failure here means a number in the new prose is not a real product constant. Remove the number rather than adding a constant to satisfy the guard.

- [ ] **Step 7: Prove each "does not do" line**

For every line in the "What coffee-bar does not do" list, name the file that makes it true, and put the pairs in the report. Start from:

```bash
grep -rn "PreventUserIdleDisplaySleep\|PreventUserIdleSystemSleep" Sources/
grep -rn "transcript_path\|last_assistant_message" Sources/ ; echo "rc=$? (1 = absent, which is the claim)"
```

The lid-closed line is true because the privileged helper is issue #13, milestone v0.2.0, and no code for it exists. Say so, and cite the absence with a command rather than from memory.

- [ ] **Step 8: Run the whole suite**

Run: `swift test`

Expected: rc=0. Report the count.

- [ ] **Step 9: Commit**

```bash
git add site/
git commit -s -S -m "docs(site): add the terms and privacy pages

v0.1.1 is the first build people run without compiling it. Apache-2.0
already disclaims warranty in sections 7 and 8, but nobody reads a licence,
so a person who double-clicks the DMG learns none of it.

Two pages, linked from the footer and deliberately not from the sidebar.
The sidebar is the product journey and a legal link there dilutes it;
footers are where readers look for this. Both pages still carry the sidebar
block, because guard 4a requires exactly one per page, so the four existing
sidebars are untouched.

The privacy page states today's behaviour as today's behaviour and names the
update check before it ships, rather than promising a state forever. It also
says plainly that GitHub serves and counts the download, because a page that
claims nothing leaves your Mac should not stay quiet about the download
itself."
```

---

### Task 4: The panel legal line

Closes gap G3. One caption line, no sheet and no new window.

**Files:**
- Modify: `Sources/CoffeeBarUI/PanelView.swift`
- Create: `Tests/CoffeeBarUITests/PanelLegalLine_test.swift`

**Interfaces:**
- Consumes: `site/terms.html` from task 3, as a published URL.
- Produces: `PanelView.legalLine() -> String` and `PanelView.legalURL() -> URL`, both `nonisolated static func`. No later task reads them.

The panel is 260 points wide and already dense. This is one line, placed between the existing version line and the Quit button.

> **WARNING — read `PanelView.swift` lines 58 to 88 before writing a character.**
>
> That comment records a real CI failure in this exact file. `SwiftUICore`
> declares `View` as `@preconcurrency @MainActor`, so members of a conforming
> type infer main-actor isolation. A swift-testing `@Test` function is
> nonisolated, so it cannot call them. The fix is the `nonisolated` keyword, and
> the comment states plainly: **"no local run catches it"**. The code compiled on
> Swift 6.3.3 locally and failed on the macos-15 runner's 6.1.2. The repo pins no
> toolchain.
>
> Therefore: **a green local suite is not evidence for these two members.** Treat
> CI as the authority.
>
> Both members are declared `nonisolated static func`, and not `nonisolated
> static let`, for one reason: `versionLine(from:)` is the only form in this
> codebase measured to compile on both toolchains. `grep -rn "nonisolated static
> let" Sources/` returns nothing, so a stored form here would be unproven on the
> toolchain that already broke once. A function reads slightly worse and is known
> to work.

- [ ] **Step 1: Write the failing test**

Create `Tests/CoffeeBarUITests/PanelLegalLine_test.swift`:

```swift
// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Testing
import Foundation
@testable import CoffeeBarUI

/// Asserts the seam the panel renders, not the drawn text.
///
/// M1 design §5.4 forbids asserting on rendered AppKit text, so a sentence
/// composed inline in `body` is a sentence no check reads. `PanelVersionLine_test`
/// makes the same argument for the version line.

private var packageRoot: URL {
    URL(fileURLWithPath: #filePath)     // …/Tests/CoffeeBarUITests/PanelLegalLine_test.swift
        .deletingLastPathComponent()    // …/Tests/CoffeeBarUITests
        .deletingLastPathComponent()    // …/Tests
        .deletingLastPathComponent()    // the package root
}

@Test func thePanelNamesTheLicenceTheRepositoryActuallyShips() throws {
    // Named bug: the panel keeps saying Apache-2.0 after the project relicenses.
    // That is a false legal claim displayed inside the product, and the two
    // facts live in different files, so nothing else would notice.
    let licence = try String(contentsOf: packageRoot.appending(path: "LICENSE"),
                             encoding: .utf8)
    #expect(licence.contains("Apache License") && licence.contains("Version 2.0"),
            "LICENSE is not Apache-2.0, so the panel line is a false claim")
    #expect(PanelView.legalLine().contains("Apache-2.0"),
            "the panel no longer names the licence the repository ships")
}

@Test func thePanelSaysThereIsNoWarranty() {
    // Named bug: the line is shortened to just the licence name to fit the
    // 260pt panel. The licence name alone tells a user nothing; "no warranty"
    // is the part that sets an expectation.
    #expect(PanelView.legalLine().contains("no warranty"))
}

@Test func theLegalLinkPointsAtThePublishedTermsPage() {
    // Named bug: a typo in the URL, or a link left pointing at the repository
    // root, so the one route from the product to its terms is dead.
    #expect(PanelView.legalURL().absoluteString
            == "https://arangogutierrez.github.io/coffee-bar/terms.html")
}

@Test func theTermsPageTheLinkPromisesExistsInThisRepository() {
    // Named bug: the link ships before the page does, or the page is renamed
    // and the panel is not updated. The site is served from `site/`, so the
    // last path component must be a file there.
    let file = PanelView.legalURL().lastPathComponent
    #expect(FileManager.default.fileExists(
        atPath: packageRoot.appending(path: "site/\(file)").path),
        "the panel links to \(file), which does not exist under site/")
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter "thePanelNames|thePanelSays|theLegalLink|theTermsPage"`

Expected: FAIL to compile, with `type 'PanelView' has no member 'legalLine'`. A compile failure is a valid red for this step.

- [ ] **Step 3: Add the two static members**

In `Sources/CoffeeBarUI/PanelView.swift`, directly below `versionLine(from:)`, add:

```swift
    /// The licence and warranty position, as one line for the panel.
    ///
    /// Composed here rather than inline in `body` for the reason
    /// `versionLine(from:)` gives: a sentence built in the view is a sentence no
    /// check can read. `PanelLegalLine_test` pins the licence name to the
    /// `LICENSE` file the repository actually ships.
    ///
    /// A `func` and not a `let`, for the reason `versionLine(from:)` documents
    /// above: `nonisolated` here is load-bearing and no local run catches a
    /// mistake. That form is the only one in this codebase measured to compile
    /// on both the local toolchain and the macos-15 runner's.
    nonisolated static func legalLine() -> String { "Apache-2.0 · no warranty" }

    /// Where the line points. The published terms page, not the repository.
    ///
    /// Force-unwrapped because the string is a literal checked by a test in the
    /// same commit: `theLegalLinkPointsAtThePublishedTermsPage` fails before a
    /// bad URL could ever reach a build.
    nonisolated static func legalURL() -> URL {
        URL(string: "https://arangogutierrez.github.io/coffee-bar/terms.html")!
    }
```

- [ ] **Step 4: Render the line in the panel**

In the same file, between the `Text(PanelView.versionLine(from:...))` block and the `Button("Quit coffee-bar")` line, insert:

```swift
            // One line, not an About sheet. The panel is 260pt wide and already
            // dense, and the DMG now reaches people who never saw the
            // repository: this is the only route from the product to its terms.
            Link(PanelView.legalLine(), destination: PanelView.legalURL())
                .font(.caption)
                .foregroundStyle(.secondary)
```

`Link` appears nowhere else in `Sources/CoffeeBarUI/`. If it does not behave inside `MenuBarExtra(.window)`, fall back to a `Button` that calls `NSWorkspace.shared.open(PanelView.legalURL())`, and say in the report which one you shipped and why.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --filter "thePanelNames|thePanelSays|theLegalLink|theTermsPage"`

Expected: all four PASS.

- [ ] **Step 6: Prove the link test discriminates**

A link test that cannot go red is theater. Point the URL at a page that does not exist and confirm two tests fail:

```bash
cp Sources/CoffeeBarUI/PanelView.swift /tmp/PanelView.swift.bak
perl -0pi -e 's{coffee-bar/terms\.html}{coffee-bar/legal.html}' Sources/CoffeeBarUI/PanelView.swift
diff /tmp/PanelView.swift.bak Sources/CoffeeBarUI/PanelView.swift
swift test --filter "thePanelNames|thePanelSays|theLegalLink|theTermsPage"
```

`diff` must print exactly one changed line. Expected: `theLegalLinkPointsAtThePublishedTermsPage` and `theTermsPageTheLinkPromisesExistsInThisRepository` both FAIL.

Restore and confirm green:

```bash
command cp -f /tmp/PanelView.swift.bak Sources/CoffeeBarUI/PanelView.swift
diff /tmp/PanelView.swift.bak Sources/CoffeeBarUI/PanelView.swift && echo "restored clean"
swift test --filter "thePanelNames|thePanelSays|theLegalLink|theTermsPage"
```

- [ ] **Step 7: Build the app and look at the panel**

```bash
scripts/build-app.sh
open build/CoffeeBar.app
```

Click the cup in the menu bar. Confirm the line reads `Apache-2.0 · no warranty`, sits under the version, and opens the terms page when clicked. Note in the report that you looked, because no unit test renders this view.

- [ ] **Step 8: Run the whole suite and commit**

Run: `swift test`

Expected: rc=0.

```bash
git add Sources/CoffeeBarUI/PanelView.swift Tests/CoffeeBarUITests/PanelLegalLine_test.swift
git commit -s -S -m "feat(ui): name the licence and the warranty position in the panel

The DMG reaches people who never saw the repository, so the panel was the
one surface that could tell them the terms and did not. This is a single
caption line under the version, not an About sheet: the panel is 260pt wide
and already dense.

Both values are static members rather than literals in body, for the reason
versionLine gives - a sentence composed in the view is a sentence no check
reads. The licence name is pinned to the LICENSE file the repository ships,
so relicensing without updating the panel turns the suite red rather than
displaying a false claim inside the product.

The URL is force-unwrapped and that is deliberate: it is a literal checked
by a test in this same commit, and a second test proves the page it promises
exists under site/. Both were mutation-checked by pointing the link at a
page that does not exist."
```

---

### Task 5: The README and the security policy

Closes gaps G4 and G6.

**Files:**
- Modify: `README.md`
- Modify: `SECURITY.md`

**Interfaces:**
- Consumes: `site/terms.html` from task 3, as a published URL.
- Produces: nothing later tasks read.

- [ ] **Step 1: Confirm the gap is still there**

```bash
grep -in "nvidia" README.md ; echo "rc=$? (1 = absent, which is the gap)"
grep -n "only outbound request" SECURITY.md
```

Expected: the README grep returns rc=1. `SECURITY.md` prints the line. If either has changed since `389f10e`, stop and report rather than editing around it.

- [ ] **Step 2: Rewrite the README licence section**

Replace the whole `## Licence` section in `README.md` with:

```markdown
## Licence

Apache-2.0. A copy ships inside the app bundle and lives in [LICENSE](LICENSE).

coffee-bar comes with **no warranty**. It does not save or recover your work,
and it cannot guarantee your Mac stays awake — macOS, another app, or an
administrator policy can sleep the machine whatever coffee-bar asks.
[What to expect](https://arangogutierrez.github.io/coffee-bar/terms.html) says
this in full.

coffee-bar is a personal project by Carlos Eduardo Arango Gutierrez. **It is not
an NVIDIA product.** NVIDIA does not endorse, support, or warrant it.

"Claude Code" is a third-party mark used nominatively; coffee-bar is not
affiliated with or endorsed by its owner.

Found a bug? [Open an issue](https://github.com/ArangoGutierrez/coffee-bar/issues/new).
```

Keep it one section. A second heading invites a second copy of the same facts.

- [ ] **Step 3: Replace the eternal claim in SECURITY.md**

In `SECURITY.md`, replace the paragraph that begins `One deliberate future exception is on record:` with:

```markdown
One deliberate future exception is on record: an update check through a Sparkle
appcast. It is not implemented and no code for it exists today. When it lands it
will be the first outbound request in the app, and this section will describe
what it sends. Any further outbound request is opt-in, off by default, and named
here before the release that carries it.

This paragraph grants no permission to add telemetry. It records that the
question is open and states the process any answer must follow.
```

The change is `the only` becoming `the first`, plus the process sentence. The old wording foreclosed a decision the project has not made, and it contradicted the versioned wording on the privacy page.

- [ ] **Step 4: Verify the claims the docs guards read**

Run: `swift test --filter DocsClaims`

Expected: PASS. `README.md` and `SECURITY.md` are documented surfaces, so the prose guards sweep both.

- [ ] **Step 5: Confirm the gap is closed**

```bash
grep -in "nvidia" README.md
grep -n "the first outbound request" SECURITY.md
grep -c "the only outbound request" SECURITY.md ; echo "expect 0"
```

- [ ] **Step 6: Run the whole suite and commit**

Run: `swift test`

Expected: rc=0.

```bash
git add README.md SECURITY.md
git commit -s -S -m "docs: state the warranty position and stop promising a closed door

The README carried the Anthropic nominative-use sentence but never said the
project is not an NVIDIA product. The site footer has said so on every page
since the redesign, and SECURITY.md says it too; the README, which is the
first thing most people read, did not. The author commits from an nvidia.com
address, so that is the surface where the omission mattered most.

SECURITY.md promised the Sparkle appcast 'will be the only outbound request
in the app'. An adversarial review flagged that this forecloses a decision
the project has not made, and that it contradicts the versioned wording the
new privacy page uses. It now says 'the first', and states the process any
further request must follow: opt-in, off by default, named here before the
release that carries it.

That is not permission to add telemetry, and the paragraph says so."
```

---

## Self-Review

**Spec coverage.** Every section of the spec maps to a task:

| Spec | Task |
|---|---|
| §5.1 licence in the bundle (G1) | 1 |
| §5.2 `NSHumanReadableCopyright` (G2) | 1 |
| §5.3 panel line (G3) | 4 |
| §6 README (G4) | 5 |
| §7.1–7.3 the two pages (G5) | 3 |
| §7.4 the footer | 3 |
| §8 `SECURITY.md` (G6) | 5 |
| §9 distribution counting | none — documentation only, §9.4 builds nothing |
| §10 guards, footer identity (G7) | 2 |
| §11 out of scope | none by design |
| §12 acceptance | folded into each task's verification steps |

**Placeholder scan.** No `TBD`, no "add error handling", no "similar to task N". Every code step carries the literal text to write. The one instruction that is not literal text — "copy the sidebar verbatim from `site/index.html`" — is deliberate: guard 4a requires byte-identity, and retyping the block is how that guard gets broken.

**Type consistency.** `PanelView.legalLine()` and `PanelView.legalURL()` are functions, not stored properties, and are called with parentheses in task 4's test, its implementation, and its mutation check. `everyPageCarriesTheSameFooter()` is named identically in task 2's implementation and in task 3's verification. The helpers `discoveredSitePages()`, `surfaceText(_:)` and `matches(_:in:)` are `internal` in `DocsClaims_test.swift` and `firstDifference(_:_:)` is `private` in `SiteClaims_test.swift`, which is why task 2 puts the new guard in the latter file.

**Known limits, stated rather than hidden.**

1. Task 1's Swift tests check the repository's `LICENSE` and the script's text. They do not run a release build. The real gate is step 6's pasted output.
2. Task 4 renders no view in a test. Step 7 is a human look, and the report must say so.
3. The footer guard proves six footers agree, not that they are right.
4. **Task 4 cannot be signed off on a local run.** `PanelView.swift` documents a
   toolchain split that already sent this file red to CI: `nonisolated` compiled
   on 6.3.3 locally and failed on the runner's 6.1.2. A green `swift test` on the
   builder's Mac is not evidence for those two members. CI is the authority.

**Three defects were found in this plan before dispatch, by checking its literals
against the tree.** They are recorded so a reader knows the checks happened:
`${ROOT}` was not a variable in `build-app.sh` and is `REPO_ROOT`; `.lede` was
not a class in `site.css` and the house class is `.eyebrow`; and `nonisolated
static let` had no precedent in a file with a documented CI-only failure, so both
new members are `nonisolated static func`.
