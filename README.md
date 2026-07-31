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

The formula lives in a dedicated tap repository,
[`ArangoGutierrez/homebrew-coffee-bar`](https://github.com/ArangoGutierrez/homebrew-coffee-bar),
because `brew tap user/repo` resolves to `github.com/user/homebrew-repo` — a
`Formula/` directory in this repository is not tappable by the conventional
one-argument command.

The tap exists and carries the formula. The install will be:

    brew tap ArangoGutierrez/coffee-bar
    brew install coffee-bar

**Neither command succeeds yet.** The formula pins a release tarball by tag and
SHA-256, and no release is tagged, so `url` points at a tag that does not exist
and `sha256` is still a placeholder. Both are pinned when the first release is
cut. Until then the formula carries a `head` block, so it can be exercised with
`brew install --HEAD ArangoGutierrez/coffee-bar/coffee-bar`.

The formula installs **both** the `coffee-bar-probe` capability probe and the
`CoffeeBar.app` menu-bar app. Homebrew formulae do not write to `/Applications`,
so the app lands in the Homebrew prefix and the install prints the one command
that links it there.

**Why a formula and not a cask, while the app is unsigned.** A cask distributes
a *downloaded* binary, and anything downloaded arrives carrying
`com.apple.quarantine`, which is what makes Gatekeeper refuse an ad-hoc signed
app. This formula builds from source on your machine, and a locally compiled
bundle never gets that attribute — measured: only `com.apple.provenance` is
present, and the app launches. So the signing work that blocks a downloadable
`.dmg` does not block this path. A cask becomes the better route once
notarisation lands, for people who would rather not build.

## Claude Code hooks

coffee-bar learns what your agent sessions are doing from Claude Code hooks and
from nothing else. It never writes your settings file for you. Until these five
hooks exist the app runs, but no session event ever reaches it.

Add them to `~/.claude/settings.json`:

```json
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "curl -sS --fail-with-body --max-time 5 --unix-socket \"$HOME/Library/Application Support/coffee-bar/ingest.sock\" -X POST --data-binary @- http://localhost/event"
          }
        ]
      }
    ],
    "PreToolUse": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "curl -sS --fail-with-body --max-time 5 --unix-socket \"$HOME/Library/Application Support/coffee-bar/ingest.sock\" -X POST --data-binary @- http://localhost/event"
          }
        ]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "curl -sS --fail-with-body --max-time 5 --unix-socket \"$HOME/Library/Application Support/coffee-bar/ingest.sock\" -X POST --data-binary @- http://localhost/event"
          }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "curl -sS --fail-with-body --max-time 5 --unix-socket \"$HOME/Library/Application Support/coffee-bar/ingest.sock\" -X POST --data-binary @- http://localhost/event"
          }
        ]
      }
    ],
    "PermissionDenied": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "curl -sS --fail-with-body --max-time 5 --unix-socket \"$HOME/Library/Application Support/coffee-bar/ingest.sock\" -X POST --data-binary @- http://localhost/event"
          }
        ]
      }
    ]
  }
}
```

The two tool events take `"matcher": "*"`; the other three take no matcher.
**If your settings file already has a `hooks` key, merge these entries into it.**
Pasting the block whole replaces whatever hooks you already run.

The app creates that socket, so start coffee-bar before the next Claude Code
session. If the socket is missing the `curl` fails and Claude Code reports a
hook error on every event. Check it is there:

    ls -l "$HOME/Library/Application Support/coffee-bar/ingest.sock"

That tells you the app is listening. It says nothing about whether your
settings file parses — Claude Code reports that itself, at session start.

## Engineering notes

- [`docs/ACCEPTED-RISKS.md`](docs/ACCEPTED-RISKS.md) — behaviour we chose to keep, with the reason and the guard.

## Licence

Apache-2.0. "Claude Code" is a third-party mark used nominatively; coffee-bar is
not affiliated with or endorsed by its owner.
