<p align="center">
  <img src="assets/art/github/readme-header-1600x400.png"
       width="800"
       alt="coffee-bar — a cup glyph with a green fill, beside the coffee-bar wordmark">
</p>

# coffee-bar

A macOS menu-bar app that binds the sleep assertion to agent session state.

**Status:** M1. The menu-bar app exists and holds the assertion from a manual
toggle, with a 20% battery floor. It does not read agent sessions yet — that
ingest is M2 — so the line above states what coffee-bar is for, not what it
does today. Nothing is released.

## M0: capability probe

    swift build
    swift run coffee-bar-probe --json

The probe answers the hardware/OS capability questions the architecture
branches on. See `docs/superpowers/specs/2026-07-27-coffee-bar-m0-probe-design.md`.

## Run the menu-bar app

    swift build
    scripts/build-app.sh
    open build/CoffeeBar.app

**coffee-bar has no Dock icon and opens no window.** It is a menu-bar app, so
after it starts, look for the cup at the right end of the menu bar, near the
clock. Click the cup to open the panel. If your menu bar is full, macOS drops
status items silently and the cup will not appear.

The panel holds a Serving switch, a battery line, and Quit. Turning Serving on
takes a `PreventUserIdleSystemSleep` assertion, so the machine stays awake. It
never takes a display assertion, so your screen still sleeps on its normal
schedule — that is the difference from `caffeinate -d`. Check both with:

    pmset -g assertions | grep coffee-bar

The bundle is unsigned. Signing and notarisation arrive with M4.

## Install

Nothing is released yet: there is no tag, so there is nothing to
`brew install` today. Build from source as above. That needs macOS 14 or
later and a Swift 6 toolchain (Xcode 16 or later).

Homebrew support arrives with M4. The formula moves to a dedicated tap repo,
`ArangoGutierrez/homebrew-coffee-bar`, because `brew tap user/repo` resolves to
`github.com/user/homebrew-repo` — a `Formula/` directory in this repo is not
tappable by the conventional command. See `docs/ROADMAP.md`. The install will
then be — and neither command works today, because
`ArangoGutierrez/homebrew-coffee-bar` does not exist yet:

    brew tap ArangoGutierrez/coffee-bar
    brew install coffee-bar

The formula builds from source, so the CLI needs no notarisation. It installs
the `coffee-bar-probe` capability probe and nothing else. It does not install
the menu-bar app.

## Licence

Apache-2.0. "Claude Code" is a third-party mark used nominatively; coffee-bar is
not affiliated with or endorsed by its owner.
