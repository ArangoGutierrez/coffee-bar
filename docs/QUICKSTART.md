# Quick start

Three steps: install it, wire the hooks, check it is listening.

coffee-bar learns what your agent sessions are doing from agent hooks and from
nothing else — it never polls, and it never inspects a running process. It never
writes your settings file for you. Until you add them, the app runs but no
session event reaches it.

This page wires Claude Code, which is the agent v0.1 supports. Codex and Cursor
have adapters in the code and no documented wiring yet. The `coffeebar-hook`
shim below posts to their endpoints, but their own configuration files are a
different shape from Claude Code's and this page documents neither.

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

The install through Homebrew is:

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

### Alternative: wire it with `coffeebar-hook`

Every command above is the same long line, and it hardcodes both the socket path
and the endpoint. Codex and Cursor post to a different endpoint, so wiring all
three agents by hand means keeping three long lines apart and getting none of
them wrong. `coffeebar-hook` is one binary that reads the payload on standard
input and posts it for you.

Nothing installs it on your `PATH` yet. Build it with the rest of the project —
see [Building](BUILDING.md) — and use the absolute path to the binary that
`swift build` produced:

```json
    "PreToolUse": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "/ABSOLUTE/PATH/TO/coffeebar-hook --tool=claude-code --socket=\"$HOME/Library/Application Support/coffee-bar/ingest.sock\""
          }
        ]
      }
    ]
```

Use that same command for every event you wire, changing only the event name it
sits under.

**Keep the `--socket` argument even though it names the default.** The health
check recognises a hook as its own by finding any of `HookHealth.commandMarkers`
in the command you wired: the socket path, or the shim's own binary name. The
command above carries both, so the panel still recognises it if you drop the
argument. Keeping it costs nothing and leaves the command recognisable by either
marker rather than by one.

`--tool` takes `claude-code`, `codex` or `cursor`, and it decides which endpoint
the payload goes to. That is the whole reason the shim exists: a payload cannot
say which agent produced it, so the sender declares it by choosing the endpoint.
An unrecognised name posts nothing rather than guessing.

The shim exits 0 whatever happens, and writes nothing to standard output —
an agent reads a hook's standard output as a decision. When coffee-bar is not
running it drops the payload in silence, because that is the normal state and a
complaint on every tool call would be worse than useless. A refusal is reported
on standard error by its status code and never by its content. Run
`coffeebar-hook --help` for the rest.

**Measured on the machine that wrote this page**, as the best of 5 runs of 100
posts each against a running coffee-bar. The shim took 1.16 s, so about 12 ms a
post. The `curl` line above took 1.66 s over the same work. About 5 ms of either
is the cost of starting any process at all: 100 runs of `/usr/bin/true` took
0.54 s. Your machine will differ, and a loaded machine differs a lot — measure
it rather than trusting these.

**What has been exercised, and what has not.** All three `--tool` values were
run end to end against a real ingest socket, each with its own recorded payload,
and each arrived under its own origin. Only the Claude Code wiring on this page
was exercised as an agent CONFIGURATION. Codex keeps its hooks in
`~/.codex/hooks.json`, and Cursor keeps its own in `~/.cursor/hooks.json` under a
flatter nesting. Neither has been wired and run here, so no recipe for either is
printed.

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
Click the cup to open the panel.

### The cup does not appear

The app is almost certainly running. On a full menu bar the cup is there and you
cannot see it, and on a MacBook with a notch it is usually behind the notch.

macOS fills menu-bar slots right to left in launch order, so the newest arrival
sits furthest left. On a bar that already carries a dozen items, furthest left is
underneath the notch. Measured on a notched MacBook: coffee-bar's item at x=929
on a 1728-point screen whose notch spans roughly 774 to 954, with a neighbouring
app's item visible at x=1186. The item was fully functional the whole time — a
click at its coordinates opened the panel normally.

First, confirm the app is running rather than broken. This is the question the UI
cannot answer for you:

    pgrep -fl CoffeeBar.app

Output means it is running and the cup is hidden, not missing. No output means it
is not running, and that is a different problem — launch it again.

Then get the item out from under the notch. Any of these works, and the first two
need nothing installed:

- **Quit coffee-bar and start it again.** It rejoins the bar in a different slot.
  Measured on the same machine: a relaunch moved the item from x=929 to x=1016,
  clear of the notch.
- **⌘-drag** any visible menu-bar item a little way along the bar. That reshuffles
  the row and can push coffee-bar out from behind the notch.
- Quit another menu-bar app to free a slot.
- A menu-bar manager — Ice, Bartender — fixes it for good.

`MenuBarExtra` gives an app no say in where its item lands, so there is nothing
coffee-bar can change here. It is documented rather than fixed.

The panel holds the Serving control, a battery line, the Waiting on you list,
the version, Preferences…, and Quit.

Display and Battery floor live in the Preferences window. Open it with
Preferences… at the foot of the panel, or with ⌘, once coffee-bar is frontmost.

| Control | Where it lives | What it decides |
|---|---|---|
| Serving | The panel | Whether to hold at all. Off is an absolute veto. |
| Display | Preferences | Whether a hold covers the screen as well as the machine. |
| Battery floor | Preferences | How much battery a hold may spend. |

The Battery floor control ships at 15%.
On battery, coffee-bar does not hold at or below 15%.
Move it up if you want the machine to sleep sooner, or down if you are beside a
charger. The floor governs every Serving position, including Auto, and it
outranks the Display control — a screen held below the floor drains the battery
faster than the hold the floor has just refused.

Your choice is remembered across launches.
