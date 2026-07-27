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
| **M4** | Open-source repo: GitHub Actions CI/release, Apache-2.0 compliance, contribution docs, Homebrew installability | **v0.1 — cut here** |
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

## Note on M0

M0 is a gate, not a shipped artifact. Its `CoffeeBarCore` and `CoffeeBarPower` modules are
the app's engine and carry forward; the journal + TTL watchdog it builds is the core M5
reuses. The probe CLI itself stays as a diagnostic.
