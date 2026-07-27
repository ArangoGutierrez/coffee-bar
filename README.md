# coffee-bar

A macOS menu-bar app that binds the sleep assertion to agent session state.

**Status:** M0 — capability probe. No UI yet.

## M0: capability probe

    swift build
    swift run coffee-bar-probe --json

The probe answers the hardware/OS capability questions the architecture
branches on. See `docs/superpowers/specs/2026-07-27-coffee-bar-m0-probe-design.md`.

## Licence

Apache-2.0. "Claude Code", "Codex" and "Cursor" are third-party marks used
nominatively; coffee-bar is not affiliated with or endorsed by their owners.
