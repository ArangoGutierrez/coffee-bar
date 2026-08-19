# Quick start

Three steps: install it, wire the hooks, check it is listening.

coffee-bar learns what your agent sessions are doing from agent hooks and from
nothing else — it never polls, and it never inspects a running process. It never
writes your settings file for you. Until you add them, the app runs but no
session event reaches it.

This page wires Claude Code, which is the agent it documents. Codex and Cursor
have adapters in the code and no documented wiring yet. The `coffeebar-hook`
shim below posts to their endpoints, but their own configuration files are a
different shape from Claude Code's and this page documents neither.

## 1. Install

<!--
  RELEASE STATUS. This section and the Status line in README.md are the only two
  places that assert whether a release exists. Keep it that way: the tag flips
  these two and nothing else.
-->
**v0.3.0 is released** as a signed, notarised DMG, and Homebrew builds v0.3.0
from source. That source build is ad-hoc signed, so the app cannot register the
privileged helper: lid-closed mode there is armed from the command line rather
than from the button. To build that source yourself, see
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

**Let coffee-bar write the entries for you.** Open Preferences… from the foot of
the panel, or press ⌘, while coffee-bar is frontmost. Under **Agent tools** each
settings file is listed with a **Copy hook snippet** button beside it. Click the
one next to `~/.claude/settings.json` and the whole block is on your pasteboard,
ready to merge into the file.

Prefer that button to the block printed below, and not only because it saves
typing. It is generated from `HookHealth.requiredEvents(for:)` — the same
constant the health check reads — so it cannot tell you to wire a set the panel
then reports as missing. It carries the ingest endpoint belonging to the tool
you picked, which is how an arriving payload is attributed to that tool at all,
and it puts the `matcher` key on exactly the events that need one. The JSON
below explains none of that, and a hook config wrong in any of those ways fails
silently: the app sees nothing and the panel still says the file is wired.

**Copy hook snippet never touches your settings file.** It writes to the
pasteboard and stops there. Merging is yours, because that file is yours.

### Or paste the block by hand

Worth doing if you want to read what you are pasting before it goes in, or if
coffee-bar is not running yet. This is the Claude Code block; the button is the
only route that prints the Codex and Cursor ones.

Add these to `~/.claude/settings.json`:

```json
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "curl -sS -o /dev/null --fail-with-body --max-time 5 --unix-socket \"$HOME/Library/Application Support/coffee-bar/ingest.sock\" -X POST --data-binary @- http://localhost/event"
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
            "command": "curl -sS -o /dev/null --fail-with-body --max-time 5 --unix-socket \"$HOME/Library/Application Support/coffee-bar/ingest.sock\" -X POST --data-binary @- http://localhost/event"
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
            "command": "curl -sS -o /dev/null --fail-with-body --max-time 5 --unix-socket \"$HOME/Library/Application Support/coffee-bar/ingest.sock\" -X POST --data-binary @- http://localhost/event"
          }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "curl -sS -o /dev/null --fail-with-body --max-time 5 --unix-socket \"$HOME/Library/Application Support/coffee-bar/ingest.sock\" -X POST --data-binary @- http://localhost/event"
          }
        ]
      }
    ],
    "PermissionDenied": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "curl -sS -o /dev/null --fail-with-body --max-time 5 --unix-socket \"$HOME/Library/Application Support/coffee-bar/ingest.sock\" -X POST --data-binary @- http://localhost/event"
          }
        ]
      }
    ]
  }
}
```

The two tool events take `"matcher": "*"`; the other three take no matcher.

**Keep `-o /dev/null`.** It pairs with `--fail-with-body`, which exists to print
the server's error body rather than swallow it — and `curl` prints a body to
standard output, which is where Claude Code looks for a hook's decision. Without
the redirect, an ingest error reaches your agent as something to act on. The
exit status, which is the part `--fail-with-body` is wanted for, is unaffected.

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
            "command": "curl -sS -o /dev/null --fail-with-body --max-time 5 --unix-socket \"$HOME/Library/Application Support/coffee-bar/ingest.sock\" -X POST --data-binary @- http://localhost/event"
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
post. The `curl` line took 1.66 s over the same work, measured before
`-o /dev/null` joined it. About 5 ms of either
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

While an agent is working you should see two lines: `PreventUserIdleSystemSleep`
named `"coffee-bar is serving"`, and `NetworkClientActive` named
`"coffee-bar is keeping the network up"`. With the Display control in the
Preferences window on its default position you should see **no** display
assertion from coffee-bar. Move that control to the other position and a third
line appears while an agent works:
`PreventUserIdleDisplaySleep`, named
`"coffee-bar is keeping the display awake"`.

## Optional: lid-closed mode

The three steps above keep your Mac awake with the **lid open**. Closing the lid
still sleeps it: a power assertion does not survive the lid, and overriding it
means changing a system setting. That is the one part of coffee-bar that needs
root, and it is opt-in. Everything above needs none.

**On a signed build, the notarised DMG, it is one button.** Open Preferences…
from the foot of the panel and, under **Power**, click
**Arm lid-closed mode**. coffee-bar asks macOS to install a small privileged
helper, and the app itself never elevates: **macOS runs that helper, not
coffee-bar**, and it takes no credentials from you to do it.

**Then go and approve it, because nothing will prompt you.** Open System
Settings → General → Login Items & Extensions and turn coffee-bar on there.
There is no dialog to accept and **no password at any point**. Until you flip
that switch the helper is installed and will not run, and the button reports a
refusal that reads like a bug and is not one.

The window then tells you the hold is armed and for how long, taken from what
the helper recorded rather than from the slider you set. **It cannot tell you
again later** — the journal that records the hold belongs to root and coffee-bar
runs as you — so ask the probe instead:

    sudo /Library/PrivilegedHelperTools/coffee-bar-probe report

**To take it away**, use **Remove the helper** in the same window. It ends the
hold first and unregisters second, so your sleep setting is never left changed
with nothing to put it back.

### On an unsigned build

**The button is disabled**, and a Homebrew install is unsigned by design: the
formula compiles the source on your machine, so the bundle carries no team
identifier and macOS has nothing to pin a helper to. The window says as much and
names the command instead.

Lid-closed mode still works there, by the route it has always had, and **that
route is not deprecated**. It is two commands, because the probe refuses to arm
itself from any directory you can write to — a launchd job runs it as root at
every boot, so a binary somebody else could swap is root persistence:

    sudo install -o root -g wheel -m 755 \
      /Applications/CoffeeBar.app/Contents/MacOS/coffee-bar-probe \
      /Library/PrivilegedHelperTools/coffee-bar-probe
    sudo /Library/PrivilegedHelperTools/coffee-bar-probe arm

A Homebrew install does not land in `/Applications`, so take the source path
from the Preferences window rather than from this page: it asks the running app
where it actually is, and this page cannot.
[How coffee-bar works](https://arangogutierrez.github.io/coffee-bar/docs.html)
explains both routes in full.

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

Display, Battery floor and Quiet everything else live in the Preferences window.
Open it with Preferences… at the foot of the panel, or with ⌘, once coffee-bar is
frontmost.

| Control | Where it lives | What it decides |
|---|---|---|
| Serving | The panel | Whether to hold at all. Off is an absolute veto. |
| Display | Preferences | Whether a hold covers the screen as well as the machine. |
| Battery floor | Preferences | How much battery a hold may spend. |
| Quiet everything else | Preferences | Whether processes you have named are demoted while an agent works. |
| Arm lid-closed mode | Preferences | Whether the Mac may stay awake with the lid shut. Signed builds only. |

The Battery floor control ships at 15%.
On battery, coffee-bar does not hold at or below 15%.
Move it up if you want the machine to sleep sooner, or down if you are beside a
charger. The floor governs every Serving position, including Auto, and it
outranks the Display control — a screen held below the floor drains the battery
faster than the hold the floor has just refused.

Your choice is remembered across launches.
