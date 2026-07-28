# M2 — Claude Code ingest design

Status: **draft, ready for a plan.** Written 2026-07-28, after M1 closed at
`80e82e5` with 209 tests.

M2 makes the product's central claim true. M1 holds an assertion from a manual
toggle; M2 binds that assertion to what an agent is actually doing.

---

## 1. Scope

### In

- A local ingest endpoint that Claude Code hooks post session events to.
- `SessionHub`: the pure state machine that turns events into `AgentSession`
  values and expires stale ones.
- Wiring `SessionHub` output into `PowerInputs.sessions`, which `PowerBroker`
  already consumes.
- An attention list in the panel.
- A read-only health check that tells the user when ingest is not wired up.

### Out

- Codex and Cursor adapters, and the `coffeebar-hook` shim. Those are M3, and
  M3 is v0.2. **The README must not imply support for them** — `ROADMAP.md:98`.
- Anything needing root. That is M5.
- Reading transcript contents. Handoff §12 forbids it; see §7 below.

---

## 2. What is already built and must not be reshaped

`AgentSession`, `AgentTool`, `SessionState` exist in `CoffeeBarCore` since M1,
in the shape handoff §5.1 fixed. `PowerBroker.decide` already reads
`inputs.sessions`. M2 adds a producer; it does not change the broker's
signature.

The wake predicate is settled and guarded:

```swift
activeStates(holdAwakeWhileBlocked: false) == [.starting, .working]
activeStates(holdAwakeWhileBlocked: true)  == [.starting, .working,
                                               .awaitingPermission, .awaitingInput]
```

Six tests added at `80e82e5` pin it across multi-session inputs. Four mutants
die against them, including `.first`-only and `.last`-only semantics.

---

## 3. The hook contract — observed, not assumed

Read off a real machine on 2026-07-28 by inspecting which fields installed hooks
actually consume. **This is the ground truth M2 builds on.**

| Event | Fields carried | Meaning for us |
|---|---|---|
| `SessionStart` | `session_id`, `cwd`, `source` | a session appears |
| `PreToolUse` | `session_id`, `cwd`, `tool_name`, `tool_input` | the agent is doing work |
| `PostToolUse` | `session_id`, `tool_name`, `tool_response` | work finished |
| `PermissionDenied` | `session_id`, `message` | the agent is blocked on the human |
| `Stop` | `session_id`, `stop_hook_active` | the turn ended |
| `PreCompact` | `session_id` | housekeeping, ignore |

`SessionStart.source` takes `startup`, `resume`, `clear`, `compact`.

### 3.1 The mapping

| Event | New state |
|---|---|
| `SessionStart` | `.starting` |
| `PreToolUse`, `PostToolUse` | `.working` |
| `PermissionDenied` | `.awaitingPermission` |
| `Stop` | `.awaitingInput` |
| no event for the stale timeout | `.stale` |

`Stop` to `.awaitingInput` is the behaviour the product exists for. The agent
has finished its turn and the human is now the bottleneck, so with
`holdAwakeWhileBlocked` at its default of false the assertion drops. The machine
sleeps while it waits for you, and wakes into work when you answer.

### 3.2 An honest gap: nothing reports session end

**The observed hook set carries no session-end event.** So `.done` and
`.failed` are not reachable from hooks alone. Two consequences:

- Do NOT write transitions into `.done` or `.failed` and pretend an event
  produces them. That repeats the M0 failure mode, where guards written from a
  description passed while asserting nothing.
- A session that ends leaves its last state behind. **Only the stale timeout
  retires it.** That makes the timeout a correctness requirement, not a nicety
  — see §5.

Whether a newer Claude Code exposes a session-end hook is an open question.
Answer it by measurement before the plan is written, not by reading docs.

---

## 4. Transport — HTTP over a unix domain socket

**Decided 2026-07-28. A recommendation panel returned HOLD.**

The listener binds a unix domain socket at

```
~/Library/Application Support/coffee-bar/ingest.sock     mode 0600
```

and speaks HTTP over it, which satisfies the roadmap's "HTTP ingest". A hook
posts with `curl --unix-socket`, which ships with stock macOS.

**The filesystem is the authenticator.** There is no port to collide with, no
token to leak or rotate, and no other local user can post. `Network.framework`
supports unix sockets, so the repo keeps its zero third-party dependencies.

Rejected: localhost TCP with a bearer token, because the token adds nothing over
file permissions against a same-user attacker while adding a secret with a
lifecycle. Rejected: localhost TCP with no auth, because the app's whole job is
holding a power assertion, and that would make the wake state forgeable by any
local process.

### 4.1 Residual risk, stated plainly

A process running as the same user can still post events. The socket stops other
users and remote hosts, not you. Given the hook itself runs as you, that is the
floor for any design short of code-signing checks on the peer.

`SECURITY.md` says the app makes no network egress. **That stays true** — a unix
socket is not network egress and the app still opens no outbound connection. The
file must be updated to describe the listener.

---

## 5. Staleness is a safety property, not a feature

Because nothing reports session end (§3.2), a crashed or killed agent would
otherwise leave a `.working` session behind and hold the machine awake forever.

- Every session carries `lastEventAt`.
- A session with no event for the stale timeout moves to `.stale`.
- `.stale` is not in either active set, so it stops holding.
- The timeout must be evaluated on a timer, not only on the next event —
  otherwise a silent agent is never noticed.

`ServingModel` already owns a repeating timer with an `isolated deinit`. Reuse
that pattern; do not introduce a second timer discipline.

**Required test:** a session in `.working` whose `lastEventAt` is older than the
timeout must not hold the assertion. Mutate the comparison to prove the test
discriminates, and check both sides of the boundary — M1 shipped two defects
where exactly one side of a comparison was unguarded.

---

## 6. Hook installation — print, never write

**Decided 2026-07-28, after a panel HARD-DISSENT was partly upheld.**

coffee-bar prints the exact JSON for the user to paste into
`~/.claude/settings.json`. **It never writes that file.** That file is shared
territory, and this workspace's anti-pattern list records a critical,
six-occurrence pattern of last-writer-wins clobber in exactly this config.

The panel's objection was upheld on its premise: with no read either, a clobbered
snippet makes ingest die silently, and the panel keeps looking healthy while
delivering nothing. That is the honesty failure that already forced a README
correction.

Its conclusion was not upheld. It argued for **visibility**, and visibility does
not require write access. So:

- coffee-bar **reads** `~/.claude/settings.json` on launch and on the refresh
  timer, and checks its own hook entries are present.
- When they are missing, the panel says so explicitly and re-offers the snippet.
- Silent failure becomes visible, recoverable failure, with no clobber risk.

**Required test:** the health check reports missing when the file lacks the
entries, present when it has them, and does not crash when the file is absent or
malformed. Read a fixture from disk; do not assert against a hand-built string
that duplicates the parser's own logic.

---

## 7. Privacy boundary

Handoff §12 forbids reading transcript contents. The hook payload carries
`transcript_path`, and M2 must **not** open it.

`lastMessage` is capped at 140 characters per §5.1. It is attacker-influenced
text that the panel renders, so treat it as untrusted: truncate, and do not
interpret it as markup.

`SECURITY.md` already states the app reads agent metadata only and never
transcript contents. That sentence becomes load-bearing in M2. **Add a test that
fails if any ingest code path opens `transcript_path`.**

---

## 8. Target layout

Following M1's precedent — pure core, framework code isolated, UI separate:

```
CoffeeBarCore     SessionHub, the state machine, staleness. NO Apple frameworks
                  beyond Foundation, so it tests without a socket or a Mac.
CoffeeBarIngest   NEW. The unix-socket listener and the HTTP framing. Depends on
                  CoffeeBarCore.
CoffeeBarUI       the attention list; consumes SessionHub output.
```

`SessionHub` must be a pure function of (previous state, event, now). Given that
shape it is fully testable from recorded payloads with no socket in the loop,
and the socket layer only has to prove it parses and delivers.

---

## 9. The binding constraint on testing

Design spec §6 of M1 forbids asserting session-transition semantics against
invented events. **M2 must begin with a capture phase.**

1. Add a temporary hook that appends every payload to a file, verbatim.
2. Drive a real Claude Code session through: start, tool use, a permission
   denial, a stop, and a resume.
3. Commit the captured payloads as fixtures.
4. Only then write the transition tests, against those fixtures.

Writing the state machine first and inventing payloads to match it is the
failure mode this project has already paid for. **The fixtures come first.**

Note the capture step edits the user's `settings.json`, so it needs the user's
explicit approval, and it must be reverted afterwards.

---

## 10. Decisions M2 must still make

1. **Does an explicit `.stop` outrank an active session?** `decide` currently
   ORs user intent with the session predicate, and the M1 note calls the OR
   provisional. If the user toggles Serving off while an agent is working, does
   the machine sleep? The six multi-session tests all use `intent: .stop` by
   design, so **the OR has no multi-session coverage.** Whatever is decided
   needs its own tests.
2. **The stale timeout value**, and whether it differs per state. A
   `.awaitingInput` session may legitimately idle for hours; a `.working` one
   going quiet for minutes is suspicious.
3. **What the attention list shows**, and its ordering.
4. **Whether a session-end hook exists** in current Claude Code (§3.2). Measure.

---

## 11. Assertion self-description — measured against `caffeinate`

Found on 2026-07-28 while verifying M1 on real hardware, by comparing our live
assertion with Apple's tool side by side.

`caffeinate` is not a different mechanism. It links `IOKit.framework` and calls
`IOPMAssertionCreateWithDescription` and `IOPMAssertionSetProperty`. Verified:

```
$ otool -L /usr/bin/caffeinate
    /System/Library/Frameworks/IOKit.framework/Versions/A/IOKit
$ nm -u /usr/bin/caffeinate | grep IOPMAssertion
    _IOPMAssertionCreateWithDescription
    _IOPMAssertionSetProperty
```

`AssertionHolder` uses the simpler `IOPMAssertionCreateWithName`. The visible
difference, from one `pmset -g assertions` run with both live:

```
pid 75894(caffeinate): PreventUserIdleSystemSleep named: "caffeinate command-line tool"
	Details: caffeinate asserting for 300 secs
	Localized=THE CAFFEINATE TOOL IS PREVENTING SLEEP.
pid 73820(coffee-bar): PreventUserIdleSystemSleep named: "coffee-bar is serving"
```

We win on attribution: our name says which product is responsible, and
`caffeinate`'s does not. **We lose on self-description.** It carries `Details`
and a localized sentence; we carry neither.

That is backwards for a product whose pitch is transparency about what keeps a
Mac awake. M2 should move `AssertionHolder` to
`IOPMAssertionCreateWithDescription` and populate:

- `kIOPMAssertionDetailsKey` — which agent session is responsible, once ingest
  exists. That information does not exist until M2, which is why this lands here
  rather than in M1.
- `kIOPMAssertionLocalizedDescriptionKey` — a human sentence.

**Constraints.** `AssertionHolder_test.swift` already asserts the live type set
is exactly `["PreventUserIdleSystemSleep"]` by reading
`IOPMCopyAssertionsByProcess`. That guard must keep passing unchanged: a richer
description must not add an assertion type. Add a test that reads the new keys
back out of live IOKit state, not off the holder's own bookkeeping — the
existing suite's discipline.

---

## 12. Acceptance

- A real Claude Code session drives the menu-bar glyph without the user touching
  the toggle.
- `pmset -g assertions` shows `coffee-bar is serving` while the agent works, and
  no line at all once it stops and waits for the human.
- Killing the agent process releases the assertion within the stale timeout.
- Removing the hook entries makes the panel say ingest is not wired up.
- No `PreventUserIdleDisplaySleep` at any point. The §6.1 invariant survives M2.
