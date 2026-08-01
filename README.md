<p align="center">
  <img src="assets/art/github/readme-header-1600x400.png"
       width="800"
       alt="coffee-bar — a cup glyph with a green fill, beside the coffee-bar wordmark">
</p>

# coffee-bar

A macOS menu-bar app that binds the sleep assertion to agent session state.

**Status:** M2. The line above now describes what coffee-bar does, not only what
it is for. The app reads Claude Code session events through five hooks, tracks
which sessions need attention, and holds the sleep assertion on a Serving switch
with Off, Auto and On positions, over a 20% battery floor. See
[Claude Code hooks](#claude-code-hooks) for the configuration it needs.

Nothing is tagged yet. Build from source until the first release.

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

The first release is not tagged yet, so build from source as above. That needs
macOS 14 or later and a Swift 6 toolchain (Xcode 16 or later).

The formula lives in a dedicated tap repository,
[`ArangoGutierrez/homebrew-coffee-bar`](https://github.com/ArangoGutierrez/homebrew-coffee-bar),
because `brew tap user/repo` resolves to `github.com/user/homebrew-repo` — a
`Formula/` directory in this repository is not tappable by the conventional
one-argument command.

Once the first release is tagged, the install is:

    brew tap ArangoGutierrez/coffee-bar
    brew install coffee-bar

**The second command does not succeed yet.** The tap exists and the first
command works. Its formula still pins a release tarball by tag and SHA-256 that
no release has produced, so the install fails on the checksum. That formula also
installs the probe alone; the version that installs `CoffeeBar.app` lands with
the first release.

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

### Optional: retire a session as soon as it ends

The five hooks above are what the app checks for. `SessionEnd` is optional and
it removes a delay. Add this entry beside them:

```json
    "SessionEnd": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "curl -sS --fail-with-body --max-time 5 --unix-socket \"$HOME/Library/Application Support/coffee-bar/ingest.sock\" -X POST --data-binary @- http://localhost/event"
          }
        ]
      }
    ]
```

Without it, a finished session stays in the list for **4 hours**. Its last event
is `Stop`, which leaves the session waiting on you, and a waiting session takes
`blockedTimeout` — 14400 seconds — not the 900-second working timeout.

That session does not hold the assertion while it waits, because a blocked
session holds nothing unless you turn on "stay awake while blocked". So the cost
is a stale row in the list, not a Mac that will not sleep.

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
