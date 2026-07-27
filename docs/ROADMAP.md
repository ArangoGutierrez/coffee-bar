# coffee-bar roadmap

Supersedes the milestone table in `coffee-bar-HANDOFF.md` §9. Revised 2026-07-27.

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
| **M1** | Menu-bar app, assertion only. Holds `PreventUserIdleSystemSleep`, **does not** hold the display assertion (§6.1) | v0.1 |
| **M2** | Claude Code adapter + SessionHub. HTTP ingest, session state machine, wake bound to agent state | v0.1 |
| **M3** | Codex + Cursor adapters + `coffeebar-hook` shim | v0.1 |
| **M4** | Open-source repo hygiene — see M4 scope below | **v0.1 — cut here** |
| **M5** | Privileged helper + lid-closed mode (`SleepDisabled`, XPC, journal watchdog) | v0.2 |
| **M6** | Power triage + telemetry (protected/demotable sets, restore-on-exit) | v0.2 |
| **M7** | Token Tap — local OTLP token accounting (handoff §15) | v0.3 |

## v0.1 definition of done

A user can `brew install` it, launch it, and have their Mac stay awake exactly while an
agent is working — with the screen off — and see which sessions need attention. No
password prompt, no root, no kernel flags, no App Store.

Concretely:

- Holds and releases `PreventUserIdleSystemSleep` bound to live agent session state
- Display sleeps normally while the system stays awake (the differentiator, §6.1)
- Attention queue for Claude Code, Codex and Cursor sessions
- Releases the assertion when every agent is blocked on the human (§5.1, `holdAwakeWhileBlocked` default false)
- Installs via Homebrew; CI green; Apache-2.0 clean; no network egress

## What v0.1 deliberately excludes

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
`caffeinate alternative`, `KeepingYouAwake alternative`, `Claude Code`, `Codex CLI`,
`Cursor`, `agent monitoring`, `prevent sleep macOS`. These belong in the description,
the first paragraph, the topics, and real headings — not a keyword dump.

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

## Note on M0

M0 is a gate, not a shipped artifact. Its `CoffeeBarCore` and `CoffeeBarPower` modules are
the app's engine and carry forward; the journal + TTL watchdog it builds is the core M5
reuses. The probe CLI itself stays as a diagnostic.
