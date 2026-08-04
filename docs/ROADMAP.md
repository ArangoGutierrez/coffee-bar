# coffee-bar roadmap

Supersedes the milestone table in `coffee-bar-HANDOFF.md` §9. Revised 2026-07-28.

Three decisions that this file previously left open are now closed. Each one is
marked **DECIDED 2026-07-28** in its own section below.

## Why this differs from the handoff

The handoff shipped `0.1` as M1–M3, which put the **root privileged helper**, the
**undocumented `SleepDisabled` flag**, and **daemon notarisation** in the first release —
the three riskiest things in the project, all before any user had the app.

This roadmap inverts that. `v0.1` is everything that needs **no elevated privilege**:
the menu-bar app, all three agent adapters, and a properly-run open-source repo. The
lid-closed pillar moves behind it, where the M0 probe's S1 answer can inform whether it
is even viable on current macOS.

## Milestones

| M | Deliverable | Ships in |
|---|---|---|
| **M0** | Capability probe CLI — answers S1, S2, S3, S5, S8 | gate only |
| **M1** | Menu-bar app, assertion only. Holds `PreventUserIdleSystemSleep`; holds the display assertion **only when the user opts in** (§6.1, issue #12) | v0.1 |
| **M2** | Claude Code adapter + SessionHub. HTTP ingest, session state machine, wake bound to agent state | v0.1 |
| **M3** | Codex + Cursor adapters + `coffeebar-hook` shim | v0.2 |
| **M4** | Open-source repo hygiene — see M4 scope below | **v0.1 — cut here** |
| **M5** | Privileged helper + lid-closed mode (`SleepDisabled`, XPC, journal watchdog) | v0.2 |
| **M6** | Power triage + telemetry (protected/demotable sets, restore-on-exit) | v0.2 |
| **M7** | Token Tap — local OTLP token accounting (handoff §15) | v0.3 |

## v0.1 definition of done

**DECIDED 2026-07-28 — v0.1 is M1 + M2 + M4.** M3 moves to v0.2.

A user can `brew install` it, launch it, and have their Mac stay awake exactly while an
agent is working — with the screen off — and see which sessions need attention. No
password prompt, no root, no kernel flags, no App Store.

Concretely:

- Holds and releases `PreventUserIdleSystemSleep` bound to live agent session state
- Display sleeps normally while the system stays awake — the differentiator, and a
  DEFAULT rather than a promise since issue #12. A Display control in the panel opts
  in, and the setting survives a restart (§6.1)
- Attention queue for **Claude Code** and **Codex** sessions. Cursor sends no
  recorded event that says the human is now the bottleneck, so a Cursor session
  stays `working` until it ends. Its `stop` hook has no captured payload, and
  this project writes no transition against an event it has never recorded
- Releases the assertion when every agent is blocked on the human (§5.1, `holdAwakeWhileBlocked` default false)
- Installs via Homebrew; CI green; Apache-2.0 clean; no network egress

### Why the cut moved

M1 alone was the recorded fast fallback. It does not work. M1 holds an assertion;
the agent signal arrives with M2. Without an adapter the app cannot bind the
assertion to agent state, so the README cannot make the central claim. The honesty
constraint below forbids making it anyway, and CodexBar already occupies the
menu-bar-for-agent-tools space. M1 alone would ship a `caffeinate` with a nicer icon
into an occupied field.

M2 covers Claude Code, the largest identifiable agent cohort. M3's two adapters are
additive against a SessionHub that already exists by then, so deferring them costs
v0.2 little and removes two spec-and-plan cycles from the path to first release.

The recommendation panel returned HOLD on this decision. The user confirmed it.

## What v0.1 deliberately excludes

- Codex and Cursor adapters, and the `coffeebar-hook` shim (M3)
- Lid-closed operation and everything requiring root (M5)
- Process demotion / power triage (M6)
- Token accounting (M7)
- Anything in handoff §12 non-goals

The M0 probe still runs S1/S2 so the M5 decision rests on measurement rather than the
conflicting sources in handoff §2.2 — but nothing in v0.1 depends on the answer.

## M4 scope — open-source repo hygiene

The release-readiness milestone. v0.1 is cut on its completion.

| Item | Requirement |
|---|---|
| **Issue templates** | `.github/ISSUE_TEMPLATE/` — bug report, feature request, config `blank_issues_enabled: false`. Bug template must collect macOS build, hardware model, coffee-bar version, and which agent tool — the fields every triage otherwise costs a round trip to obtain. |
| **PR template** | `.github/pull_request_template.md` — problem, approach, testing done, breaking changes, `Closes #N`. |
| **CONTRIBUTING.md** | Build from source, run tests, TDD expectation, `_test.swift` naming rule and why, DCO sign-off + GPG signing requirement, conventional commit format, how to run the capability probe. |
| **SECURITY.md** | Private disclosure route, supported versions, explicit scope statement: coffee-bar reads agent metadata only and never transcript contents (handoff §12), makes no network egress, and — once M5 lands — what the privileged helper may do. |
| **README** | Optimised for both search and generative-engine retrieval. See below. |
| **CI** | GitHub Actions, minimal but real: `swift build`, `swift build -c release`, `swift test`. Least-privilege `permissions:`, `timeout-minutes`, `concurrency` with `cancel-in-progress`, actions pinned by SHA rather than moving tags. |
| **Repo description** | Short GitHub description + topics, consistent with the README's positioning. |
| **Homebrew** | Installable via `brew`. Formula builds from source; tap layout decided and documented. |

### README: SEO and GEO

Two different retrieval paths, one document.

**SEO** — the terms a person types: `macos menu bar app`, `keep mac awake`,
`caffeinate alternative`, `KeepingYouAwake alternative`, `Claude Code`,
`agent monitoring`, `prevent sleep macOS`. These belong in the description,
the first paragraph, the topics, and real headings — not a keyword dump.

`Codex CLI` and `Cursor` are **v0.2 terms, not v0.1 terms.** The v0.1 cut moved M3 to
v0.2, so ranking for them before the adapters exist would claim support the app does
not have — which the honesty constraint below forbids. Add them to the description and
topics when M3 lands, not before.

**GEO** (generative-engine optimisation) — being accurately citable when an assistant is
asked "what keeps my Mac awake while my coding agent runs?". That rewards different
properties than SEO:

- A one-sentence definition near the top that answers "what is this" without context.
- Self-contained, quotable claims. "Releases the wake assertion when every agent is
  blocked on the human" is retrievable; "smart power management" is not.
- Explicit comparison to the known alternative (KeepingYouAwake, `caffeinate -d`),
  since that is the phrasing users bring to an assistant.
- Concrete requirements stated as facts: macOS version floor, Apple Silicon, no root
  required in v0.1, no network egress.
- Q&A-shaped headings matching real questions ("Does it work with the lid closed?" —
  answered honestly for v0.1: no, that is M5).
- Every capability claim traceable to something true. Overstating here is both a
  product lie and, once assistants cite it, a durable one.

**Honesty constraint, binding on both:** no claim may outrun the probe. Handoff §2.1 is
explicit that no mechanism exists to promote a process onto P-cores — the README says
"quiet everything else", never "boost agents". Battery numbers appear only once S6's
measurement harness has produced them.

## M5 security precondition — the journal is an instruction to a root process

Found during M0 Task 5 (2026-07-27) and recorded before M5 inherits it.

`FileJournalStore` writes to `/Library/Application Support/coffee-bar/state/`,
measured at **0755 directories, 0644 journal**. Nothing currently pins those modes
or verifies that every component of the path is root-owned.

That is harmless in M0, where the probe runs as the user and only affects itself.
It stops being harmless in M5. There, a **root** helper reads that file and acts on
it: the journal says "restore `SleepDisabled` to `priorValue`", and the helper does
it. A file a non-root process can create or modify is therefore an instruction
channel into a privileged process.

Concrete failure: if the directory does not exist and an unprivileged process
creates the path first, it owns the file the root helper will later trust.

Binding requirements for M5, none of which are satisfied today:

1. The helper verifies **every** component of the journal path is owned by root
   and not group/other-writable, before reading — not just the leaf.
2. The helper refuses to act on a journal it did not write, or whose ownership or
   mode does not match expectation, and quarantines it instead.
3. Directory and file are created by the **privileged** side with explicit modes
   (`0700` / `0600`), never left to whatever created the path first.
4. `armedBy` provenance (pid, binary path, uid) is treated as **advisory
   forensics, not authentication**. It is attacker-controlled data in this threat
   model.

This is a design precondition, not a code review nit: it must be true before the
helper reads its first journal, because the whole point of the helper is that it
does something the user cannot.

## The release job and `main` — DECIDED 2026-07-28

**Decision: the formula moves to a separate tap repo, `ArangoGutierrez/homebrew-coffee-bar`.
The release job stops writing to any branch. A human pins the formula per release.**

### The conflict this resolves

`.github/workflows/release.yml` line 173 runs `git push origin HEAD:main` from the
`formula` job, which holds `contents: write`. **Branch protection on `main` is itself
an M4 deliverable.** The day it lands it breaks every release.

### The measured fact that decided the layout

`brew tap --help` states that the one-argument form resolves `user/repo` to
**`github.com/user/homebrew-repo`**. All eight taps installed on the development host
carry that prefix (`anchore/homebrew-grype`, `docker/homebrew-tap`,
`goreleaser/homebrew-tap`, `nvidia/homebrew-holodeck`, and four more).

So a `Formula/` directory inside `ArangoGutierrez/coffee-bar` is **not tappable by the
conventional command**. `README.md` already documents the two-argument workaround. The
tap repo is therefore not only the branch-protection fix — it is the only layout in
which the v0.1 install story reads the way users expect.

A second constraint ruled out automating the push: `GITHUB_TOKEN` is scoped to its own
repository, so a cross-repo write needs a stored PAT or GitHub App. That credential
controls what `brew install coffee-bar` fetches. On a project whose pitch is an
auditable helper with no network egress, that is a real supply-chain surface, and about
three releases are planned.

### The residual risk, named because it was argued

The recommendation panel returned **HARD-DISSENT** on this decision and preferred
keeping one repo with the release job opening a PR. Its objection is sound and is not
dismissed: hand-editing the formula replaces an automated chain — hex-alphabet check,
64-character length check, `grep -c` substitution counts, and `ruby -c` — with human
transcription of a URL and a 64-character digest.

The user overrode the dissent, accepting the tap layout. The objection binds the
implementation instead:

1. Port the existing checks from `release.yml` into a script in the tap repo, run by
   the tap's own CI on every pull request. The checks must fail the PR, not merely
   report.
2. Never hand-type the digest. The release job prints it, and the human copies it.
3. The tap's CI must run `brew audit --strict` and install the formula before merge, so
   a wrong digest fails there rather than in a user's terminal.

Without item 1 the panel's objection stands unanswered.

### M4 execution checklist

- [x] Create `ArangoGutierrez/homebrew-coffee-bar` — created by the user 2026-07-29
- [x] Move `Formula/coffee-bar.rb` there; delete `Formula/` from this repo — moved byte-identically, blob `ec33de9c` both sides
- [x] Strip the `formula` job from `release.yml`; keep the `verify` job
- [ ] Port the substitution checks into the tap's CI, per the three items above
- [x] Update `README.md` to the one-argument `brew tap ArangoGutierrez/coffee-bar`
- [ ] Enable branch protection on `main`, required check `build-test` (`ci.yml`)

### Two related residuals, still open

The workflow checksums GitHub's **generated source tarball**, which is not contractually
byte-stable. A release-asset tarball uploaded by the job is the robust form. This moves
with the formula and is not fixed by the decision above.

The workflow is named `Release` but creates no GitHub Release. Left out deliberately as
unrequested outward-facing scope.

## What "managed settings present" means — DECIDED 2026-07-28

**Decision: existence → `passive`. Any managed-settings file disables the Token Tap,
whether or not it carries OTEL keys.**

Raised during M0 Task 9 (S8 recon) and deliberately not resolved there. Handoff §15.4
mode 3 says *"managed settings present"* → `passive`. Its own justification is narrower:
a generic `OTEL_EXPORTER_OTLP_ENDPOINT` in managed settings governs every signal and
strips lower-precedence overrides, so mode 1 is unavailable **there**. Those are not the
same rule:

| Reading | A managed file with no OTEL keys | Consequence if wrong |
|---|---|---|
| **Existence** → passive | passive | Token Tap needlessly disabled for a fleet whose managed profile has nothing to do with telemetry |
| **Content** → passive | ownIt / fanOut | coffee-bar writes telemetry config that managed settings silently override, and the user sees nothing |

The decision picks the failure direction: **a feature that is off and says so** beats a
feature that is on and silently broken. An MDM-managed fleet is exactly where the user
has least ability to diagnose the silent case.

### Measured, so the basis is on the record

Taken on the development host, 2026-07-28:

| Input | Value |
|---|---|
| `/Library/Application Support/ClaudeCode/managed-settings.json` | absent |
| `~/.claude/settings.json` mentions `OTEL_` | 0 |
| `~/.codex/config.toml` has `[otel]` | 0 |

Both readings return `ownIt` here. **This host cannot discriminate them**, which
confirms the recorded S8 answer and establishes that no local measurement favours
either rule. The choice is policy, and no future measurement on this machine will
settle it.

The recommendation panel returned **HARD-DISSENT**, preferring deferral on the grounds
that the existence rule is broader than the spec's own justification requires. That is
accurate, and it is the deliberate content of the decision rather than an oversight.
The user overrode the dissent. The counterweight the dissent did not price: this
question had already been carried forward unresolved by three documents, and M7 would
have inherited it with no more evidence than exists today.

### What changes, and what does not

**No code changes now.** `TelemetryRecon.detectMode()` keeps the content reading. M0's
job is to report, and the probe already emits `managedSettingsPresent` and
`userSettingsHasOTEL` as separate evidence keys, so both signals survive in every
report. M7 applies the rule at its own call site.

**Binding on M7:** treat `managedSettingsPresent == true` as `passive`, regardless of
`userSettingsHasOTEL`. Tell the user the Tap is off and why. Do not cache the result —
an MDM-managed machine can acquire managed settings at any time.

Related gaps in the same probe, all deliberate M0 scope limits and none of them closed
by this decision:
- Only three sources are inspected. **Live `OTEL_*` environment variables are
  invisible**, and §15.4's precedence story is largely about env vars. This is the
  biggest gap and the obvious next increment.
- Project-scope settings and `settings.local.json` are not consulted.
- `~/.cursor/hooks.json` is not consulted.
- Detection is text search, not parse: `OTEL_` anywhere in the JSON counts, including
  in a comment or a deny rule. Conservative, but noisy.

## Design principle: no hidden durations

**If the UI does not expose a time control, the behaviour is indefinite.**

A user-facing hold lasts until the user ends it. coffee-bar does not invent a
duration the user cannot see, cannot change, and did not ask for. A toggle that
silently expires after N minutes is a bug report waiting to happen — the machine
sleeps, the user does not know why, and nothing in the interface explains it.

Current behaviour already complies. The POC's assertion is created with no
timeout and is released only on toggle-off; `pmset -g assertions` shows no
`Timeout will fire` line for it, unlike `caffeinate -t`.

### The one exception, and why it is not one

The `SleepDisabled` TTL in M5 (8h hard cap, handoff §8.2(5)) *is* a fixed
duration the user cannot raise. It is not a convenience timer — it is a safety
interlock on a **root-level, global, reboot-surviving** kernel flag. If coffee-bar
is killed while that flag is set, nothing else on the system will clear it, and
the failure mode is a laptop that never sleeps again and cooks in a bag.

The distinction that matters:

| | User-facing hold | `SleepDisabled` TTL |
|---|---|---|
| Scope | this process' assertion | system-wide, survives reboot |
| Cleared by | toggling off, or process exit | nothing, unless we clear it |
| Duration | **indefinite** | capped at 8h |
| Purpose | do what the user asked | bound the blast radius of a crash |

So the rule stands as written: no hidden durations on anything the user controls.
A cap on a privileged global flag that outlives the process is a different thing
wearing a similar shape.

## Competitive check — 2026-07-27

Two facts established before M4 invests in naming and copy.

**The name is free.** `brew search --formula coffee-bar` and
`brew search --cask coffee-bar` both return no match (only the fuzzy
`coffeescript`). This closes handoff §16 Q5, which required the check before the
first public commit. The GitHub repo already exists, is **public**, and is empty —
so the first push is the first public commit.

**CodexBar exists, and the handoff's §11 landscape misses it.**

| | |
|---|---|
| Cask | `codexbar`, v0.45.2, https://codexbar.app/ |
| Description | "Menu bar usage monitor for Codex and Claude" |
| Requires | macOS >= 14 — the same floor as coffee-bar |
| Ships | `CodexBar.app` plus a `CodexBarCLI` helper binary |
| Installs | **8,282 / 30 days · 14,237 / 90 days · 18,574 / 365 days** |

This is a real product with real adoption occupying the menu-bar-for-agent-tools
space, and it overlaps **M7's Token Tap** almost exactly. Handoff §15.10 argues the
Token Tap is "the thing that makes coffee-bar worth opening when no agent is
running" — that claim is now contested by an incumbent, so it must not be made
without qualification.

Consequences, in priority order:

1. **The re-scoped v0.1 is the right call, and this is independent evidence for
   it.** coffee-bar's defensible ground is the power side — an assertion whose
   lifetime is bound to agent state, display-off-while-awake as the default, and
   releasing the assertion precisely when every agent is blocked on a human.
   Nothing in that list is usage monitoring. v0.1 = M0–M4 ships exactly that.
2. **M4 copy must not claim novelty in usage monitoring.** No "the only tool
   that…" phrasing about tokens. When M7 lands, the honest framing is that
   coffee-bar joins token data to the battery delta — which requires holding both
   streams — not that local token accounting is new.
3. **SEO/GEO must account for it.** Users will ask assistants for a "CodexBar
   alternative". Being accurately retrievable for that means stating plainly what
   coffee-bar does that CodexBar does not (wake policy, power) and what it does
   not do (as of v0.1, no token accounting at all).
4. **Re-run this check before v0.1 ships.** A 30-day install count is a moving
   number and the field is active.

## Note on M0

M0 is a gate, not a shipped artifact. Its `CoffeeBarCore` and `CoffeeBarPower` modules are
the app's engine and carry forward; the journal + TTL watchdog it builds is the core M5
reuses. The probe CLI itself stays as a diagnostic.
