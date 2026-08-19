<p align="center">
  <img src="assets/art/github/readme-header-1600x400.png"
       width="800"
       alt="coffee-bar — a cup glyph beside the coffee-bar wordmark">
</p>

# coffee-bar

A macOS menu-bar app that binds the sleep assertion to agent session state.

Your Mac stays awake while a coding agent is working, and sleeps the moment the
agent is waiting on **you**. The screen still sleeps on its normal schedule —
that is the difference from `caffeinate -d`.

<!--
  RELEASE STATUS lives in exactly one place: the line below. Every other
  sentence in this repository is written to stay true whether or not a release
  exists, so the tag flips ONE line here plus the install note in
  docs/QUICKSTART.md. Before adding a second status claim anywhere, change this
  one instead.
-->
**Status: v0.3.0 is released as a signed, notarised DMG, and the Homebrew tap
now builds v0.3.0 from source. That source build is ad-hoc signed, so the app
cannot register the privileged helper: lid-closed mode is armed by the command
route below instead.**
See [Building](docs/BUILDING.md).

## Quick start

[**docs/QUICKSTART.md**](docs/QUICKSTART.md) — install it, wire the Claude Code
hooks, and check it is listening. coffee-bar does nothing until those hooks
exist; it reads session state from agent hooks and from nothing else.

## What it does

- Under `Auto`, holds `PreventUserIdleSystemSleep`, bound to live agent session
  state.
- Asks macOS for `NetworkClientActive` alongside it, so a held Mac is not left
  awake with its network clients dropped. **Awake but unreachable is the failure
  this exists to prevent.** It is a request and not a promise: macOS may decline
  it on battery or under thermal pressure.
- **Holds no display assertion by default.** Your screen sleeps normally while
  the work continues. A Display control in the Preferences window opts in when
  you do want the screen kept on.
- Under `Auto`, releases when every agent is blocked on a human, not when a
  timer expires.
- Shows how many sessions are working, and which ones are waiting on you.
- Retires a session whose agent crashed, so a dead process cannot pin the
  machine awake forever.
- A Serving switch with Off, Auto and On. **Off is an absolute veto.**
- A battery floor: at or below 15% on battery, it does not hold.
- Asks what it needs to know the first time it runs: whether to hold the
  display, where to put the battery floor, and which agent tools to listen for.
- Opens at login once you ask it to, and installs nothing until you do.
- Says when a newer version is published. It downloads no update and never
  replaces itself.
- Answers `/status` on the same unix socket the hooks post to, so an agent can
  read what coffee-bar is doing: the switch position, whether a hold is live,
  and how many sessions are working or waiting on you. Read-only, and it
  carries no session identity, no working directory and no message text.

It has no Dock icon and opens no window. Look for the cup at the right end of
the menu bar.

coffee-bar makes exactly one outbound request. At most once a day when it
starts, and whenever you press Check now, it asks this project's site which
release is current; it carries no identifier and no query string, and there is
no setting that turns it off. Everything else stays on the machine.
[Security](SECURITY.md) prints that request in full.

## Lid-closed mode

Everything above holds the Mac awake with the **lid open**. Closing the lid still
sleeps it, because a power assertion does not survive the lid — overriding it
means changing a system setting, and that needs root.

coffee-bar's everyday work needs no root and no password, and the app never
elevates its own privilege. Lid-closed mode is an opt-in extra, and the only
part of the product that involves root at all. There are two routes into it: the
**Arm lid-closed mode** button on a signed build, and `sudo coffee-bar-probe arm`
everywhere else. A Homebrew install has only the second, and that one asks for
your password because `sudo` does.

- **One button on a signed build.** The notarised DMG carries an
  **Arm lid-closed mode** button in the Preferences window, under Power. coffee-bar
  asks macOS to install a small privileged helper, and **macOS runs that helper,
  not coffee-bar.** The app process never elevates: it takes no credentials and
  runs no interpreter as root.
- **Approval is yours, and nothing prompts you for it.** macOS files the helper
  away switched off, and you turn it on under System Settings → General → Login
  Items & Extensions. On this route there is no dialog to accept and **no
  password, at any point.** If you are waiting for something to pop up, nothing
  will: the first click reports that the helper is waiting on you, and you press
  the button again once you have approved it.
- **It is removable from the same window**, and removal ends the hold before it
  unregisters, so the sleep setting is never left changed with nothing to put it
  back.
- **The hold has a length, and it is yours to set.** You choose it in
  Preferences, the `sudo` command the window prints carries the same number, and
  24 hours is the ceiling either way. A root process still holding the setting
  after whatever armed it has gone is the failure that ceiling exists to bound.
- **On an unsigned build the button is disabled.** A Homebrew install is
  unsigned by design: the formula compiles the source on your machine, so the
  bundle carries no team identifier and macOS has nothing to pin a helper to.
  Those builds arm the mode with `sudo coffee-bar-probe arm`, the route it has
  always had. That route is **not deprecated**.

coffee-bar tells you the mode is armed at the moment you arm it from the
Preferences window. It cannot answer that question afterwards — the journal
belongs to root and the app runs as you — so the probe's own `report` verb is
what answers it later.
[How lid-closed mode works](https://arangogutierrez.github.io/coffee-bar/docs.html)
has the whole flow, both routes, and the reasoning.

## Documentation

| | |
|---|---|
| [Quick start](docs/QUICKSTART.md) | Install, hooks, first-run check |
| [Building](docs/BUILDING.md) | Toolchain, building from source, the capability probe |
| [Accepted risks](docs/ACCEPTED-RISKS.md) | Behaviour we chose to keep, with the reason and the guard |
| [Roadmap](docs/ROADMAP.md) | Milestones and what each one ships |
| [Security](SECURITY.md) | Reporting, the network and privacy boundaries |

## Licence

Apache-2.0. A copy ships inside the app bundle and lives in [LICENSE](LICENSE).

coffee-bar comes with **no warranty**. It does not save or recover your work,
and it cannot guarantee your Mac stays awake — macOS, another app, or an
administrator policy can sleep the machine whatever coffee-bar asks.
[What to expect](https://arangogutierrez.github.io/coffee-bar/terms.html) says
this in full.

coffee-bar is a personal project by Carlos Eduardo Arango Gutierrez. **It is not
an NVIDIA product.** NVIDIA does not endorse, support, or warrant it.

"Claude Code" is a third-party mark used nominatively; coffee-bar is not
affiliated with or endorsed by its owner.

Found a bug? [Open an issue](https://github.com/ArangoGutierrez/coffee-bar/issues/new).
