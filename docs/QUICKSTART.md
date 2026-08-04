# Quick start

Three steps: install it, wire the hooks, check it is listening.

coffee-bar learns what your agent sessions are doing from Claude Code hooks and
from nothing else. It never writes your settings file for you. Until you add
them, the app runs but no session event reaches it.

## 1. Install

<!--
  RELEASE STATUS. This section and the Status line in README.md are the only two
  places that assert whether a release exists. Keep it that way: the tag flips
  these two and nothing else.
-->
**v0.1.1 is released** as a signed, notarised DMG. Homebrew still builds from
source and installs 0.1.0. The two tags carry the same code, so v0.1.1 is that
source, newly signed. To build that source yourself, see
[Building](BUILDING.md). It takes about a minute.

Once the first release is tagged, the install is:

    brew tap ArangoGutierrez/coffee-bar
    brew install coffee-bar

The formula lives in a dedicated tap repository,
[`ArangoGutierrez/homebrew-coffee-bar`](https://github.com/ArangoGutierrez/homebrew-coffee-bar),
because `brew tap user/repo` resolves to `github.com/user/homebrew-repo` — a
`Formula/` directory in this repository is not tappable by the conventional
one-argument command.

Homebrew formulae do not write to `/Applications`, so the app lands in the
Homebrew prefix and the install prints the one command that links it there.

## 2. Wire the Claude Code hooks

Add these to `~/.claude/settings.json`:

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

Each hook you add starts delivering its own events. The health check asks for
all five hooks before it reports the install as complete.

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

That session does not hold the assertion while it waits. A session that waits on
you holds nothing. So the cost is a stale row in the list, not a Mac that will
not sleep.

## 3. Check it is listening

The app creates the socket, so start coffee-bar before the next Claude Code
session. If the socket is missing, the `curl` fails and Claude Code reports a
hook error on every event.

    ls -l "$HOME/Library/Application Support/coffee-bar/ingest.sock"

That tells you the app is listening. It says nothing about whether your settings
file parses — Claude Code reports that itself, at session start.

Then confirm the assertion behaves:

    pmset -g assertions | grep coffee-bar

While an agent is working you should see `PreventUserIdleSystemSleep` named
`"coffee-bar is serving"`. With the panel's Display control on its default
position you should see **no** display assertion from coffee-bar. Move that
control to the other position and a second line appears while an agent works:
`PreventUserIdleDisplaySleep`, named
`"coffee-bar is keeping the display awake"`.

## Where to look in the UI

coffee-bar has no Dock icon and opens no window. It is a menu-bar app, so after
it starts, look for the cup at the right end of the menu bar, near the clock.
Click the cup to open the panel. If your menu bar is full, macOS drops status
items silently and the cup will not appear.

The panel holds a Serving switch, a battery line, and Quit.
