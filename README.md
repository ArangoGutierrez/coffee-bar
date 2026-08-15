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
**Status: v0.1.1 is released as a signed, notarised DMG. Homebrew still
builds from source and installs 0.1.0. The two tags carry the same code, so
v0.1.1 is that source, newly signed.**
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

It has no Dock icon and opens no window. Look for the cup at the right end of
the menu bar.

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
