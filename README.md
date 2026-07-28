# coffee-bar

A macOS menu-bar app that binds the sleep assertion to agent session state.

**Status:** M0 — capability probe. No UI yet.

## M0: capability probe

    swift build
    swift run coffee-bar-probe --json

The probe answers the hardware/OS capability questions the architecture
branches on. See `docs/superpowers/specs/2026-07-27-coffee-bar-m0-probe-design.md`.

## Install

Nothing is released yet: there is no tag, so there is nothing to
`brew install` today. Build from source as above. That needs macOS 14 or
later and a Swift 6 toolchain (Xcode 16 or later).

Homebrew support arrives with M4. The formula moves to a dedicated tap repo,
`ArangoGutierrez/homebrew-coffee-bar`, because `brew tap user/repo` resolves to
`github.com/user/homebrew-repo` — a `Formula/` directory in this repo is not
tappable by the conventional command. See `docs/ROADMAP.md`. The install will
then be:

    brew tap ArangoGutierrez/coffee-bar
    brew install coffee-bar

The formula builds from source, so the CLI needs no notarisation. It installs
the `coffee-bar-probe` capability probe and nothing else — the menu-bar app is
M1, see `docs/ROADMAP.md`.

## Licence

Apache-2.0. "Claude Code", "Codex" and "Cursor" are third-party marks used
nominatively; coffee-bar is not affiliated with or endorsed by their owners.
