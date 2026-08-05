<!--
Copyright 2026 Carlos Eduardo Arango Gutierrez
SPDX-License-Identifier: Apache-2.0
-->

# coffee-bar legal surface — design

**Date:** 2026-08-05
**Status:** approved
**Scope:** three surfaces — the app bundle, `README.md`, and the GitHub Pages site

## 1. Goal

Give a person who installs the notarised DMG a plain-English statement of what
coffee-bar does, what it does not do, what it sends, and where to report a bug.
Close the one place where the project does not comply with its own licence.

The steer is **minimum**. This design adds no legal apparatus the project does
not need. It fixes a compliance gap, states expectations once per surface, and
stops there.

## 2. Facts this design rests on

Every row comes from a command run against `389f10e` on 2026-08-05. A builder
must re-run these and report any delta before writing copy.

| Fact | Source of truth | Value |
|---|---|---|
| Distribution channel | `CHANGELOG.md:47-48` | signed DMG, `Developer ID Application`, team `85FN4Z37V8` |
| App Store status | `site/index.html:314`, spec D8 | **not on the Mac App Store**, ruled out by design |
| Licence | `LICENSE` | Apache-2.0 |
| `NOTICE` file | `git cat-file -e origin/main:NOTICE` | **absent**, so Apache-2.0 §4(d) does not apply |
| `LICENSE` inside the app bundle | `scripts/build-app.sh`, resource block | **absent**. Only the binary and the glyphs are copied. |
| `NSHumanReadableCopyright` | `scripts/build-app.sh`, `Info.plist` heredoc | **absent** |
| Site pages | `git ls-tree origin/main -- site/` | `index`, `install`, `docs`, `changelog` |
| Site footer | `sed -n '/<footer>/,/<\/footer>/p' site/*.html` | byte-identical on all four pages |
| Apple + NVIDIA disclaimer | site footer `<p class="tm">`, `SECURITY.md:21` | **already present** on the site and in the policy |
| Same disclaimer in `README.md` | `grep -in nvidia README.md` | **absent**, rc=1 |
| Same disclaimer in the app | `grep -rin nvidia Sources/` | **absent** |
| Anthropic disclaimer | `README.md`, Licence section | present, nominative use of "Claude Code" |
| Network promise | `SECURITY.md:74-77` | "resolves no host, opens no network connection, and sends nothing anywhere" |
| Future exception | `SECURITY.md:107-110` | the Sparkle appcast "**will be the only** outbound request in the app" |
| Update check | issue #29, milestone v0.3.0 | not implemented, no code exists |
| Page auto-discovery | `SiteClaims_test.swift`, `discoveredSitePages()` | every page under `site/` is swept |
| Sidebar guard 4a | `everyPageCarriesTheSameSidebar()` | each page carries **exactly one** `<nav class="sidebar">`, byte-identical across pages |
| Version guard 3 | `everyPageShowsTheNewestReleasedVersion()` | each page carries **exactly one** `<p class="sidebar-version">` naming the newest tag |
| Footer guard | `SiteClaims_test.swift` | **none exists.** The footer is unguarded. |
| DMG downloads | `gh api repos/ArangoGutierrez/coffee-bar/releases` | `coffee-bar-0.1.1.dmg`, `download_count` = **5** |
| Tap formula url | tap `Formula/coffee-bar.rb` | GitHub's auto-generated tarball for `v0.1.1`, **not** a release asset |
| Tap clones, 14 days | `gh api repos/ArangoGutierrez/homebrew-coffee-bar/traffic/clones` | 30 clones, **25 unique** |
| Repo traffic, 14 days | `gh api repos/ArangoGutierrez/coffee-bar/traffic/views` | 38 views, 1 unique |

**Warning.** Row 9 corrects an error made during brainstorming. The design lead
stated the Apple and NVIDIA disclaimer was "missing everywhere". It is present
on all four site pages and in `SECURITY.md`. Only the README and the app lack
it. Do not add it to the site again.

## 3. What is already true, and must not be rebuilt

The project has more legal cover than it appears to. Restating any of this in a
new page creates a second copy that drifts.

- **Apache-2.0 is the terms and conditions.** Its text is titled "TERMS AND
  CONDITIONS FOR USE, REPRODUCTION, AND DISTRIBUTION". Section 7 disclaims
  warranty. Section 8 limits liability. No new contract is needed or wanted.
- **Apple imposes nothing.** coffee-bar ships under a Developer ID, not through
  the Mac App Store. Notarisation is an automated malware scan. There is no App
  Review, and no mandatory privacy-policy or support URL.
- **The trademark and endorsement disclaimer already ships** on every site page
  and in `SECURITY.md`.
- **`SECURITY.md` already documents the privacy boundary** in depth: no
  transcript reads, no network egress, and the reasoning behind each.

The gap is not legal cover. The gap is that nobody reads a licence, so a person
who double-clicks the DMG learns none of it.

## 4. The gap list

| # | Gap | Surface | Severity |
|---|---|---|---|
| G1 | The DMG distributes the Work with no copy of the Licence inside it. Apache-2.0 §4(a) requires one. | app | **compliance defect** |
| G2 | The bundle carries no copyright notice in its metadata. | app | hygiene |
| G3 | The panel names no licence and no warranty position. | app | expectations |
| G4 | The README carries no Apple or NVIDIA disclaimer, and no expectations note. | README | expectations |
| G5 | The site states expectations nowhere a worried reader would look. | site | expectations |
| G6 | `SECURITY.md` promises the appcast "will be the only outbound request", which forecloses a decision the project has not made. | policy | future contradiction |
| G7 | Six hand-copied footers, and no guard against drift. | site | drift risk |

G1 is the only item that is not optional.

## 5. Surface 1 — the app

### 5.1 Ship the licence inside the bundle (G1)

`scripts/build-app.sh` copies `LICENSE` into `${CONTENTS}/Resources/LICENSE`.

The copy follows the pattern the glyph block already uses, and for the reason
that block already states: the exit code of `cp` proves nothing, so the script
checks that the file arrived.

```sh
command cp -f "${REPO_ROOT}/LICENSE" "${CONTENTS}/Resources/LICENSE"
[ -s "${CONTENTS}/Resources/LICENSE" ] \
    || die "LICENSE did not land in the bundle"
```

`-s` rather than `-f`: an empty licence file satisfies `-f` and complies with
nothing.

**The variable is `REPO_ROOT`.** An earlier draft of this spec wrote `${ROOT}`,
which is not defined in `build-app.sh` and would have expanded to nothing. The
script defines `SCRIPT_DIR`, `REPO_ROOT`, `PRODUCT`, `APP_NAME`, `BUNDLE_ID`,
`OUT_DIR`, `APP`, `CONTENTS` and `ART`. Check the name against the script
before you paste this block.

### 5.2 Name the copyright holder in the metadata (G2)

The `Info.plist` heredoc gains one key:

```xml
<key>NSHumanReadableCopyright</key>
<string>Copyright 2026 Carlos Eduardo Arango Gutierrez. Apache-2.0. A personal project, not an NVIDIA product.</string>
```

macOS shows this string in Get Info and in the standard About panel. It costs
one key and puts the disclaimer inside the signed artifact, where it travels
with the binary rather than with the website.

### 5.3 One line in the panel (G3)

`PanelView` gains a single caption line directly under the existing version
line, above the Quit button:

> Apache-2.0 · no warranty

The text links to the terms page on the site. The panel is 260 points wide and
already dense, so this is one line and not a sheet, a window, or an About
panel. The line is composed by a static function, in the same style as
`versionLine(from:)`, so a test can read it without building a view.

**Out of scope:** a full About panel, a licence viewer, and a first-run consent
dialog. None of them is required, and each adds a surface to maintain.

## 6. Surface 2 — the README (G4)

The existing `## Licence` section grows by two sentences. It does not become a
new section, because a second heading invites a second copy of the same facts.

The section states, in this order:

1. Apache-2.0.
2. The software comes with no warranty, and points at the terms page for the
   plain-English version.
3. coffee-bar is a personal project. It is not an NVIDIA product. NVIDIA does
   not endorse, support, or warrant it.
4. The existing nominative-use sentence about "Claude Code", unchanged.
5. Where to report a bug: the GitHub issue tracker.

Item 3 is the sentence with the highest value on this surface. The author
commits from an `nvidia.com` address, and the README is the first thing a
reader sees. The site already says this; the README does not.

## 7. Surface 3 — the site (G5)

### 7.1 Two new pages

| File | Title | Purpose |
|---|---|---|
| `site/terms.html` | Terms | what it does, what it does not do, no warranty, how to report a bug |
| `site/privacy.html` | Privacy | what it reads, what it never reads, what leaves the Mac |

Both pages are linked from the footer. Neither is added to the sidebar. The
sidebar is the product journey — Home, Install, Docs, Changelog — and a legal
link there dilutes it. Legal links belong in a footer, where readers look.

**Both pages still carry the sidebar block.** Guard 4a sweeps every discovered
page and requires exactly one `<nav class="sidebar">` per page, byte-identical
to the others. A page with no sidebar fails the guard. The sidebar's *contents*
do not change, so the four existing pages are not edited for navigation.

Each new page also carries exactly one `<p class="sidebar-version">` naming the
newest tag, per guard 3.

### 7.2 What `terms.html` says

Five sections, in this order.

1. **What coffee-bar does.** Three sentences, drawn from `README.md`. It holds
   a sleep assertion while an agent works. It releases when every agent waits
   on a human. It holds no display assertion by default.

2. **What coffee-bar does not do.** This section carries the most weight, and
   every line must be true of the shipped build:
   - It does not save, back up, or recover your work.
   - It does not guarantee your Mac stays awake. macOS, another app, or a
     policy can sleep the machine regardless.
   - It does not keep the Mac awake with the lid closed. That needs a
     privileged helper, and it is not in v0.1.1.
   - It does not read your agent conversations.
   - It does not change what your agent does.

3. **No warranty.** Plain English, then the pointer:

   > coffee-bar is provided as is, with no warranty of any kind. If it fails to
   > hold your Mac awake, or holds it awake when you did not want it, you carry
   > that outcome. The binding text is the Apache-2.0 Licence, sections 7 and 8.

4. **Who makes it.** A personal project by Carlos Eduardo Arango Gutierrez,
   under Apache-2.0. Not an NVIDIA product.

5. **Report a bug.** A direct link to
   `https://github.com/ArangoGutierrez/coffee-bar/issues/new`, with one line on
   what to include: the version from the panel, the macOS version, and what you
   expected.

The page ends with a version stamp: **"This page describes v0.1.1."**

### 7.3 What `privacy.html` says

1. **What it reads.** Agent session metadata delivered by hooks over a unix
   domain socket. Three local configuration files, read to find an already
   configured OTLP endpoint.

2. **What it never reads.** The contents of your agent conversations.
   `transcript_path` and `last_assistant_message` are dropped at the decode
   boundary, and `PrivacyBoundary_test.swift` guards it.

3. **What leaves your Mac.** In v0.1.1, nothing. There is no account, no
   telemetry, no analytics, and no crash reporting. The one socket the app
   opens is a unix domain socket, which has no address, no port, and no route
   off the machine.

4. **What may change, named in advance.** A future release adds a check for
   updates (issue #29). That check is the first request that leaves the Mac.
   When it ships, this page names what it sends before the release goes out.

5. **Downloading is a separate thing.** One short paragraph, because a reader
   who is told "nothing leaves your Mac" may reasonably wonder about the
   download itself:

   > Getting coffee-bar is a normal web request. GitHub serves the download and
   > counts it, as it does for every file it hosts. That is GitHub's logging,
   > under GitHub's privacy policy, and it happens before coffee-bar runs. The
   > app itself sends nothing.

   This paragraph exists so the page is honest, not because the project is
   liable for it. Do not turn it into a cookie or tracking notice: the site
   sets no cookie, loads no font, and calls no CDN.

6. **The version stamp:** "This page describes v0.1.1."

Section 4 is the versioned wording the goal calls for. It states today's
behaviour as today's behaviour, and it commits to naming a change before the
change ships, rather than promising a state forever.

### 7.4 The footer (G7)

The footer gains two links and keeps everything it already carries:

```
Apache-2.0 · Terms · Privacy · Report a bug
Source on GitHub
Built by Carlos Eduardo Arango Gutierrez.
[the existing trademark paragraph, unchanged]
```

The footer is then byte-identical across all six pages.

## 8. The `SECURITY.md` correction (G6)

`SECURITY.md:107-110` currently reads that the appcast "will be the only
outbound request in the app". That sentence forecloses a decision the project
has not made, and it contradicts the versioned wording `privacy.html` uses.

Replace the eternal claim with a versioned commitment and a process:

> One deliberate future exception is on record: an update check through a
> Sparkle appcast. It is not implemented and no code for it exists today. When
> it lands it will be the first outbound request in the app, and this section
> will describe what it sends. Any further outbound request is opt-in, off by
> default, and named here before the release that carries it.

This is the change the adversarial panel demanded, and it is correct. Without
it, the site says "this may change" while the policy says "only, ever", and the
two drift.

**This section grants no permission to add telemetry.** It records that the
decision is open and states the process a future decision must follow.

## 9. Distribution counting

The maintainer wants to know how many people take the app. This section records
what already answers that, why it is not telemetry, and what the project
deliberately does **not** build.

### 9.1 It is not telemetry

The counting happens on GitHub's servers, for requests a person makes to GitHub.
The app sends nothing, opens no socket, and contains no counting code. The
network promise in `SECURITY.md` is untouched, and no consent dialog is needed.

A future reader must not mistake the privacy page for a ban on this. The privacy
page describes what **the app** sends. It says nothing about what GitHub logs
when somebody downloads a file, because the project does not control that and
never did.

### 9.2 The two counters that already exist

| Question | Read it with | Limit |
|---|---|---|
| How many took the DMG? | `gh api repos/ArangoGutierrez/coffee-bar/releases --jq '.[].assets[] \| "\(.name) \(.download_count)"'` | counts requests, not people |
| How many use Homebrew? | `gh api repos/ArangoGutierrez/homebrew-coffee-bar/traffic/clones` | counts `brew tap`, not `brew install` |

The website Download button needs nothing. It links straight at the release
asset, so a click is a download, and the asset counter already sees it. This
also keeps the "no analytics, no CDN" comment at the top of every page true.

### 9.3 What the numbers cannot tell you

State these limits beside any figure quoted from them.

1. `download_count` counts **requests**. Retries, bots and mirrors are included.
   It is a floor, not a count of humans.
2. The traffic API keeps **14 days**. History older than that is gone, and no
   job snapshots it.
3. The tap clone count measures `brew tap`, which includes CI and anyone who
   cloned the tap for any reason. `brew install` is **invisible**, because the
   formula points at GitHub's auto-generated tarball, and GitHub publishes no
   counter for those.
4. Both measure **acquisition, not use**. A person who downloads the app and
   never opens it counts the same as a daily user.

Limit 4 is the honest argument for shipping issue #29. An update check is the
only mechanism on the roadmap that distinguishes an install from a user.

### 9.4 Decisions taken

- **Do not** upload a source tarball as a release asset to give Homebrew its own
  counter. The precision does not yet justify a change to the release process.
- **Do not** add a scheduled job to snapshot the traffic numbers.
- **Do not** add analytics to the site.
- Read the two counters by hand when the number is wanted.

Revisit 9.4 only when a decision depends on the Homebrew figure.

## 10. Guards

| Guard | File | What it catches |
|---|---|---|
| Footer identity | `SiteClaims_test.swift`, new | one of six hand-copied footers drifting from the others |
| Bundle licence | `scripts/build-app.sh`, inline | a build that ships without the Apache-2.0 text |
| Panel legal line | a `CoffeeBarUITests` check on the static composer | the line disappearing in a refactor |

The footer guard mirrors guard 4a exactly: read the `<footer>` block from every
discovered page, compare each to the first, and name the first differing line.
It shares 4a's stated limit — six identical footers that are all wrong still
pass.

A builder must not weaken guard 4a to accommodate the new pages. If a new page
fails 4a, the page is wrong, not the guard.

## 11. Out of scope

- Telemetry of any kind, meaning code in the app that sends anything. A separate
  design decides it, if it is ever decided. Reading GitHub's download counters
  is **not** telemetry, and section 9 covers it.
- A source tarball as a release asset, and the formula change that would give
  Homebrew its own install counter. Recorded in section 9.4.
- A scheduled job that snapshots the traffic numbers before the 14-day window
  drops them. Recorded in section 9.4.
- A cookie banner. The site sets no cookie, loads no font, and calls no CDN.
- A privacy policy written as a legal instrument. Apache-2.0 §7 and §8 carry
  the legal weight; these pages carry the plain-English explanation.
- Any change to the Mac App Store position. It stays ruled out.
- A first-run consent dialog.

## 12. Acceptance

A builder reports this work done only with the output of each command pasted
into the report.

1. `swift test` passes, with the test count stated, run against the final tree.
2. `scripts/build-app.sh` runs, and `ls -l build/CoffeeBar.app/Contents/Resources/LICENSE` shows a non-empty file.
3. `plutil -extract NSHumanReadableCopyright raw -o - build/CoffeeBar.app/Contents/Info.plist` prints the string.
4. The new footer guard fails when one footer is edited by hand, and passes when it is restored. Paste both runs.
5. `grep -c 'sidebar-version' site/terms.html site/privacy.html` prints `1` for each.
6. `grep -in nvidia README.md` returns a match.
7. Every "does not do" line in `terms.html` is traced to the source file that makes it true.
8. Both counter commands in section 9.2 run and print a number. Paste the output. This proves the commands are correct before anyone relies on them.
9. `grep -c 'analytics' site/terms.html site/privacy.html` shows the new pages add no tracking script.
