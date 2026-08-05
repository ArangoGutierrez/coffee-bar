# coffee-bar — Engineering Handoff

**Status:** design brief, pre-implementation
**Target:** native macOS menu-bar app, Swift 6 / SwiftUI, macOS 14+
**Owner:** Eduardo Arango
**Implementer:** Claude Code
**Date:** 2026-07-27

---

## 0. How to use this document

This is a design brief, not a spec to be executed literally. Sections 2 and 3 contain
**premise corrections** that invalidate parts of the original product idea; read them before
writing code. Section 10 lists **spikes that must run before M2** — several load-bearing
assumptions are unverified on current hardware/OS and the architecture branches on the result.

Do not start with UI. Start with the capability probe (M0).

---

## 1. Product thesis

KeepingYouAwake (MIT, `newmarcel/KeepingYouAwake`) is a one-bit tool: it holds an
`IOPMAssertion` so the Mac does not idle-sleep. It is agent-unaware, display-unaware, and
battery-unaware.

coffee-bar's thesis: **in the agentic era the wake state should be a function of agent state,
not a toggle.** The machine should stay awake exactly while an agent is working, stay awake
with the screen off and the lid shut, wake the user when an agent is blocked, and spend the
remaining battery on the agent rather than on Electron apps.

Three capabilities, in priority order:

1. **Agent-driven wake.** Sessions register via agent hooks; the sleep assertion is held while
   any registered session is in a non-terminal state and released automatically when the last
   one finishes. No manual toggling, no forgotten flags.
2. **Attention queue.** A menu-bar list of live agent sessions with state
   (`working` / `awaiting-permission` / `awaiting-input` / `done` / `failed` / `stale`),
   elapsed time, and repo. Click to focus the owning terminal/window.
3. **Power triage on battery.** Reduce everything that is not the agent: display off, E-core
   demotion of contending processes, Spotlight/Time Machine suppression, with an explicit
   protected set (Teams/Slack/Zoom) that is never touched.

The coffee metaphor is the surface (serve / refill / decaf / thermal "too hot to serve"), not
the architecture. Keep it in copy and iconography; keep it out of type names.

**Non-goals** are in §12. Read them — they prevent the two most likely scope explosions.

---

## 2. Premise audit

Four claims in the original brief are wrong or only conditionally true. The design must be
built around the corrected versions.

### 2.1 "The app can prioritise battery power for agent processes"

**False as stated.** macOS exposes no per-process power budget, no per-process energy
reservation, and no supported way to promote a process's scheduling priority or core
assignment. Oakley's testing is explicit: `taskpolicy -b -p <pid>` demotes all threads of a
process to background QoS (E-cores only), `-B` reverses that demotion, and **no mechanism
exists to promote background threads onto P-cores** — the tool "functions as a brake, but not
as an accelerator" (Oakley-2022, `eclecticlight.co/2022/10/20/making-the-most-of-apple-silicon-power-5-user-control/`;
confirmed Oakley-2024, `eclecticlight.co/2024/12/17/tune-for-performance-core-types/`).

The only lever is **contention reduction**: make everything else cheaper so the agent gets more
of a fixed budget. That is a real, measurable effect, but it must be described honestly in
both the code and the UI. Do not ship a "Boost agents" switch. Ship "Quiet everything else".

Corollary for UI copy: the metaphor is *the café closes the kitchen so the espresso machine
gets the power*, not *the espresso machine gets a bigger power line*.

### 2.2 "The app can keep the machine awake with the lid closed"

**Conditionally true, and not via `IOPMAssertion`.** Power assertions
(`kIOPMAssertionTypePreventUserIdleSystemSleep`, what `caffeinate -i` and KeepingYouAwake use)
suppress *idle* sleep only. Lid close is a separate, non-idle sleep trigger and is not vetoed
by any assertion.

The mechanism that does work is the undocumented `SleepDisabled` flag,
`sudo pmset -a disablesleep 1`, which `IOPMrootDomain` treats as a veto surviving the lid-close
event. Sources conflict on Apple Silicon:

- Multiple mid-2026 sources report firsthand Apple Silicon success, and an entire product
  category (Sleepless, Wedge, LidRun, Droppy) is built on it
  (`apple.gadgethacks.com/how-to/how-to-keep-macbook-awake-with-lid-closed-3-scenarios-explained/`, 2026-06;
  `getdroppy.app/blog/keep-macbook-awake-lid-closed`, 2026-07).
- One source claims a Ventura-era hardware lid-magnet interlock defeats it on Apple Silicon
  and that clamshell mode with an external display is the only path
  (`pasqualepillitteri.it/en/news/779/disable-laptop-sleep-lid-close-ai-agents`, 2026-04).

Weight of recent evidence favours "it works", but this **must be a runtime capability probe,
not a compile-time assumption** (spike S1). The feature ships behind the probe and degrades
gracefully to assertion-only mode.

Three consequences that shape the architecture:

- `SleepDisabled` is **global, persistent, and survives reboot**. It is not scoped to a
  process or a session, and nothing in the UI tells the user it is set. A crashed coffee-bar
  that leaves it at 1 produces the exact failure the app exists to prevent: a hot laptop in a
  bag at 4%. **A crash-safe revert path is a hard requirement, not a nice-to-have** (§8).
- It requires root, therefore a privileged helper (§5.3), therefore no App Store (§13.3).
- Raw `disablesleep` leaves the **internal display powered at full brightness under a closed
  lid**, silently burning the battery you were trying to save
  (`apple.gadgethacks.com/...`, 2026-06). coffee-bar must force display sleep before/at lid
  close. This is the single most valuable thing the app does that a shell alias does not.

### 2.3 "Users add Teams/Slack/WhatsApp so they can take a meeting"

The original brief is ambiguous about which list those apps go into. The stated scenario —
on battery, in a meeting, agents running — means **Teams/Slack/Zoom must be protected from
throttling, not throttled**. Design three explicit sets, never two:

| Set | Semantics | Default membership |
|---|---|---|
| `agents` | Detected agent processes. Never touched. Their liveness drives the wake assertion. | auto-detected (§5.4) |
| `protected` | Never demoted, never suspended, regardless of profile. | conferencing + audio + VPN + `WindowServer`-adjacent, user-extensible |
| `demotable` | Eligible for E-core demotion under `Aggressive`. | everything else the user opts in |

Default `demotable` to **empty**. Opt-in only. An app that silently E-core-demotes a
compile job or a video call will be uninstalled the same day.

### 2.4 "This should be written in Go"

Go is the wrong tool here and the standing preference does not apply. `MenuBarExtra`,
`SMAppService`, `NSXPCConnection`, `IOPMAssertion`, `NSProcessInfo.thermalState`, and code
signing all require the Apple toolchain. Use **Swift 6** for the app, the daemon, and the hook
shim, in one SwiftPM package. Introducing a second toolchain to write a 200-line stdin-to-socket
shim is not worth the build and notarisation complexity.

---

## 3. Capability matrix

What macOS actually permits, and at what privilege level. This table is the contract; anything
not in it is not available.

| Capability | API / mechanism | Privilege | Notes |
|---|---|---|---|
| Prevent idle system sleep | `IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep)` | user | The KeepingYouAwake baseline. Does **not** cover lid close. |
| Prevent idle display sleep | `kIOPMAssertionTypePreventUserIdleDisplaySleep` | user | coffee-bar's default is **not** to hold this — see §6.1. |
| Prevent disk idle | `kIOPMAssertPreventDiskIdle` | user | Rarely needed on SSD-only hardware; skip. |
| Prevent lid-close sleep | `pmset -a disablesleep 1` (`SleepDisabled`) | **root** | Global, persistent, undocumented. Probe first (S1). |
| Force display off | `pmset displaysleepnow`, or `IOPMAssertionDeclareUserActivity` inverse / `IODisplayWrangler` idle | user | Required alongside `disablesleep`. Verify in S2. |
| Demote a process to E-cores | `setpriority(PRIO_DARWIN_PROCESS, pid, PRIO_DARWIN_BG)` / `/usr/sbin/taskpolicy -b -p` | user (same uid) — **verified**, S5 | Brake only. Inherited by children. |
| Undo demotion | `setpriority(PRIO_DARWIN_PROCESS, pid, 0)` / `/usr/sbin/taskpolicy -B -p` | user — **verified**, S5 | Clears only the EXTERNAL channel. A process that backgrounded ITSELF keeps that state — measured. |
| Promote a process | — | — | **Does not exist.** (Oakley-2022) |
| Suspend a process | `kill(pid, SIGSTOP)` / `SIGCONT` | user (same uid) | Aggressive tier only. Risks dropped websockets, TLS session death. |
| Disable App Nap for another app | `defaults write <bundle-id> NSAppSleepDisabled -bool YES` | user | Requires app restart. Offer as a suggestion, do not apply silently. |
| Per-process energy | `proc_pid_rusage(pid, RUSAGE_INFO_V4+, ...)` → `ri_billed_energy` etc. | user | Same source Activity Monitor's Energy Impact derives from. Verify field availability (S3). |
| System power source / battery | `IOPSCopyPowerSourcesInfo`, `IOPSGetTimeRemainingEstimate` | user | Charging state, %, time remaining. |
| Thermal pressure | `ProcessInfo.processInfo.thermalState` + `.thermalStateDidChangeNotification` | user | KVO-able. Safety interlock input. |
| Low Power Mode state | `ProcessInfo.processInfo.isLowPowerModeEnabled` | user | Read-only. Toggling requires root (`pmset -b lowpowermode`). |
| Enumerate all processes | `proc_listpids` / `proc_pidpath` / `sysctl KERN_PROCARGS2` | user | Needed for argv-based agent detection. Blocks sandboxing. |
| Suppress Spotlight indexing | `mdutil -a -i off` | **root** | Reversible; must be restored. Aggressive tier only. |
| Suppress Time Machine | `tmutil disable` | **root** | Aggressive tier only. |

---

## 4. Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│ CoffeeBar.app  (LSUIElement, SwiftUI MenuBarExtra, user session) │
│                                                                  │
│  ┌────────────┐  ┌──────────────┐  ┌──────────────────────────┐  │
│  │ SessionHub │  │ PowerBroker  │  │ MenuBarUI / Settings     │  │
│  │  (state    │◄─┤ (policy      │◄─┤ (SwiftUI)                │  │
│  │   machine) │  │  engine)     │  └──────────────────────────┘  │
│  └─────▲──────┘  └──────┬───────┘                                │
│        │                │                                        │
│  ┌─────┴──────────────┐ │  ┌─────────────────┐                   │
│  │ IngestServer       │ │  │ AssertionHolder │  (IOPMAssertion)  │
│  │  HTTP 127.0.0.1    │ │  └─────────────────┘                   │
│  │  + UNIX socket     │ │  ┌─────────────────┐                   │
│  └─────▲──────────────┘ └─►│ ProcGovernor    │  (PRIO_DARWIN_BG) │
│        │                   └─────────────────┘                   │
│  ┌─────┴──────────────┐                                          │
│  │ ProcSampler (2 Hz) │  libproc fallback discovery              │
│  └────────────────────┘                                          │
└────────┬──────────────────────────────┬──────────────────────────┘
         │ sudo (root CLI)              │ writes config
         ▼                              ▼
┌────────────────────────┐   ┌────────────────────────────────────┐
│ probewatchdog (root)   │   │ ~/.claude/settings.json (http hook)│
│ launchd daemon, root   │   │ ~/.codex/hooks.json      (command) │
│  · SleepDisabled       │   │ ~/.cursor/hooks.json     (command) │
│  · mdutil / tmutil     │   └────────────────────────────────────┘
│  · watchdog + TTL      │
└────────────────────────┘
                              ┌────────────────────────────────────┐
                              │ coffeebar-hook (CLI shim)          │
                              │  stdin JSON / argv → UNIX socket   │
                              │  always exit 0; fast, and bounded  │
                              └────────────────────────────────────┘
```

**Design invariants**

- The daemon holds no policy. It executes verbs (`setSleepDisabled(Bool)`,
  `setSpotlight(Bool)`) with a TTL and a heartbeat. All decisions live in `PowerBroker`.
- The app never blocks an agent. Every ingest path fails open (§5.5).
- Every mutation to global system state is journaled to disk before it is applied, so the
  daemon can revert after an unclean exit (§8.2).

---

## 5. Component specs

### 5.1 SessionHub — session state machine

One `AgentSession` per agent conversation, keyed by `(tool, sessionID)`.

```swift
enum SessionState: String, Codable {
    case starting          // SessionStart seen, no turn yet
    case working           // turn in flight
    case awaitingPermission // blocked on a permission prompt  → ATTENTION
    case awaitingInput     // idle prompt / elicitation        → ATTENTION
    case done              // turn ended cleanly
    case failed            // StopFailure / non-zero exit      → ATTENTION
    case stale             // no event and no owning pid for N minutes
}

struct AgentSession: Identifiable, Codable {
    let id: String              // "\(tool):\(sessionID)"
    let tool: AgentTool         // .claudeCode | .codex | .cursor
    let sessionID: String
    var cwd: URL?
    var repoName: String?       // basename or `git rev-parse --show-toplevel`
    var pid: pid_t?             // resolved best-effort, see 5.4
    var state: SessionState
    var stateEnteredAt: Date
    var lastEventAt: Date
    var lastMessage: String?    // Notification body / stopReason, truncated 140
    var attentionSince: Date?
    var turnCount: Int
}
```

Transitions are driven by ingested events (§5.5) with a sampler-driven fallback (§5.4).
`stale` is entered when `now - lastEventAt > staleTimeout` **and** no live pid matches;
`stale` sessions do not hold the wake assertion.

**Wake predicate:** `shouldStayAwake == sessions.contains { $0.state ∈ [.starting, .working] }`
— note that `awaitingPermission` and `awaitingInput` do **not** hold the assertion by default,
because the agent is blocked on the human and burning battery pointlessly. This is a policy
knob (`holdAwakeWhileBlocked`, default `false`) and is a genuinely differentiating behaviour.

### 5.2 PowerBroker — policy engine

Pure function of inputs → desired system state. No I/O, fully unit-testable.

```
inputs:  sessions, powerSource(.ac|.battery), batteryPercent, timeRemaining,
         thermalState, lidClosed, profile, userOverride
output:  DesiredPowerState {
             idleSleepAssertion: Bool
             displaySleepAssertion: Bool
             sleepDisabled: Bool           // requires daemon
             demoteSet: Set<pid_t>
             suspendSet: Set<pid_t>
             spotlightSuppressed: Bool
             timeMachineSuppressed: Bool
         }
```

Profiles:

| Profile | idle assertion | display assertion | `SleepDisabled` | demote | suspend | Spotlight/TM |
|---|---|---|---|---|---|---|
| `Off` (decaf) | no | no | no | — | — | — |
| `Espresso` (default) | while working | **no** | no | — | — | — |
| `Doppio` (lid-closed) | while working | no | yes + forced display off | protected-safe set | — | — |
| `Aggressive` | while working | no | yes | `demotable` | `demotable ∩ userSuspendable` | suppressed |

`Aggressive` requires an explicit per-session confirmation, never sticky.

### 5.3 PrivilegedHelper — `com.coffeebar.helper` — SUPERSEDED

> **None of this section shipped. It records the design M5 did NOT build.**
> Carlos decided on 2026-08-05 that M5 ships as a root CLI (`sudo
> coffee-bar-probe arm`) plus the launchd daemon `com.coffeebar.probewatchdog`,
> with no XPC and no `SMAppService`, because the only bundle that ships is
> ad-hoc signed and the peer pinning below cannot be satisfied on it.
> `SECURITY.md` is the authoritative bound on what shipped, and
> `noTargetOnThePrivilegedPathReachesForXPCOrSMAppService` refuses these APIs in
> code. This section is kept as the record of a road not taken; the verb list
> below is superseded by `ProbeVerb`, and `heartbeat` in particular never
> existed.

- Installed via `SMAppService.daemon(plistName:)` (macOS 13+). Do **not** use the deprecated
  `SMJobBless` path.
- `NSXPCListener(machServiceName:)`, protocol pinned by `NSXPCConnection` code-signing
  requirement matching on both ends (`setCodeSigningRequirement(_:)`, macOS 13+). Reject any
  peer that does not match the app's Team ID and bundle ID.
- Verbs are narrow and non-parameterised by arbitrary strings — no "run this command".

```swift
@objc protocol CoffeeBarHelperProtocol {
    func probeCapabilities(reply: @escaping (Data) -> Void)          // S1/S2 results
    func setSleepDisabled(_ on: Bool, ttlSeconds: Int,
                          reply: @escaping (Bool, String?) -> Void)
    func setSpotlightIndexing(_ on: Bool, reply: @escaping (Bool, String?) -> Void)
    func setTimeMachine(_ on: Bool, reply: @escaping (Bool, String?) -> Void)
    func heartbeat(reply: @escaping (Void) -> Void)
    func currentState(reply: @escaping (Data) -> Void)
}
```

Every state-mutating verb takes a TTL. See §8.2 for the watchdog contract.

### 5.4 Agent discovery — process sampler

Hooks are the primary signal; the sampler is the fallback and the pid resolver.

- Enumerate with `proc_listpids(PROC_ALL_PIDS)`, path via `proc_pidpath`, argv via
  `sysctl([CTL_KERN, KERN_PROCARGS2, pid])`.
- Match rules (config-driven, shipped as defaults, hot-reloadable):
  - Claude Code: process path ends in `node`/`bun` **and** argv contains a path segment
    `.../claude` or argv[0] basename `claude`. Also match a `claude` native binary directly.
  - Codex: argv[0] basename `codex`.
  - Cursor: `Cursor Helper (Plugin)` / `Cursor Helper (Renderer)` under
    `/Applications/Cursor.app`; the agent runs in-process, so treat the app bundle as the unit.
- Map a session to a pid by walking the process tree from candidate agent pids and comparing
  `cwd` (via `proc_pidinfo(PROC_PIDVNODEPATHINFO)`) against the hook-reported `cwd`. This is
  heuristic; tolerate `pid == nil`.
- Sample at 2 Hz when any session is non-terminal, 0.2 Hz otherwise. Sampling is itself a
  battery cost; do not poll at 10 Hz "for smoothness".

**Heuristic fallback state inference** (used only when no hooks are configured for a tool):
sustained CPU > threshold ⇒ `working`; CPU ≈ 0 with a live controlling TTY for > 45 s ⇒
`awaitingInput` (low confidence — mark the row as `~` in the UI). Never escalate a low-confidence
inference to a notification.

### 5.5 Agent adapters — ingest

This is the highest-value integration surface and it is well-documented per tool.

#### Claude Code — HTTP hooks (preferred, no shim)

Claude Code supports `type: "http"` hook handlers that POST the event JSON to a URL, with the
response body using the same JSON output schema as command hooks
(code.claude.com/docs/en/hooks). Errors — non-2xx, connection failure, timeout — are
**non-blocking**, so a stopped coffee-bar cannot break a session. That fail-open property is
why HTTP is the right transport here.

Write to `~/.claude/settings.json` (user scope), merging rather than replacing:

```json
{
  "hooks": {
    "SessionStart":  [{ "hooks": [{ "type": "http", "url": "http://127.0.0.1:8787/v1/event", "timeout": 2 }] }],
    "UserPromptSubmit": [{ "hooks": [{ "type": "http", "url": "http://127.0.0.1:8787/v1/event", "timeout": 2 }] }],
    "Notification":  [{ "hooks": [{ "type": "http", "url": "http://127.0.0.1:8787/v1/event", "timeout": 2 }] }],
    "Stop":          [{ "hooks": [{ "type": "http", "url": "http://127.0.0.1:8787/v1/event", "timeout": 2 }] }],
    "StopFailure":   [{ "hooks": [{ "type": "http", "url": "http://127.0.0.1:8787/v1/event", "timeout": 2 }] }],
    "SessionEnd":    [{ "hooks": [{ "type": "http", "url": "http://127.0.0.1:8787/v1/event", "timeout": 2 }] }]
  }
}
```

Set `timeout: 2` explicitly. The default for `http` handlers is **600 s**; leaving it default
means a wedged coffee-bar could stall an agent turn for ten minutes.

Event mapping — the `Notification` matcher values are exactly the attention taxonomy this app
needs:

| Hook event / matcher | → `SessionState` | Attention |
|---|---|---|
| `SessionStart` | `starting` | no |
| `UserPromptSubmit` | `working` | no |
| `Notification` / `permission_prompt` | `awaitingPermission` | **yes** |
| `Notification` / `idle_prompt` | `awaitingInput` | **yes** |
| `Notification` / `agent_needs_input` | `awaitingInput` | **yes** |
| `Notification` / `elicitation_dialog` | `awaitingInput` | **yes** |
| `Notification` / `agent_completed` | `done` | yes (configurable) |
| `Stop` | `done` | configurable |
| `StopFailure` | `failed` | **yes** — carries `rate_limit`, `overloaded`, `billing_error`, etc. |
| `SessionEnd` | remove session | no |

Common input fields available on every event: `session_id`, `cwd`, `transcript_path`,
`permission_mode`, `hook_event_name`; `agent_id` / `agent_type` inside subagents. That is
enough to populate the whole model. **Never read `transcript_path` contents** — see §12.

Response body: always `200` with `{}`. coffee-bar must never return a `decision` or
`permissionDecision`. It is an observer.

Optional stretch: distribute the whole integration as a **Claude Code plugin** with
`hooks/hooks.json`, so setup is `/plugin install` instead of settings surgery. Evaluate in M4.

#### Codex CLI — command hooks + legacy `notify`

Codex's hook engine reached stable in v0.124.0 (2026-04-23). Documented events:
`SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `PermissionRequest`,
`PreCompact`, `PostCompact`, `SubagentStart`, `SubagentStop`, `Stop`. **Command handlers only** —
no HTTP type — so the `coffeebar-hook` shim is required here.

**Corrected 2026-08-05, by measurement against codex-cli 0.146.0.** Everything this section
used to say about TOML hook tables was wrong, and it was wrong in the expensive direction:
believing it is why `HookHealth` shipped with no Codex reader at all for two milestones, and
why the panel handed a Codex user a Claude Code advisory.

Hooks live in **`~/.codex/hooks.json`**, and that file is JSON in **Claude Code's exact
nesting** — `hooks.<Event>[].matcher` beside `.hooks[].command`, with PascalCase event names.
So `HookHealth` parses Codex and Claude Code with one reader, and this project needs no TOML
parser and no dependency to get one.

```json
// ~/.codex/hooks.json
{
  "hooks": {
    "SessionStart": [
      {"hooks": [{"type": "command",
                  "command": "/usr/local/bin/coffeebar-hook --tool=codex",
                  "timeout": 2}]}
    ],
    "PreToolUse": [
      {"matcher": "Bash|apply_patch|Edit|Write",
       "hooks": [{"type": "command",
                  "command": "/usr/local/bin/coffeebar-hook --tool=codex",
                  "timeout": 2}]}
    ],
    "Stop": [
      {"hooks": [{"type": "command",
                  "command": "/usr/local/bin/coffeebar-hook --tool=codex",
                  "timeout": 2}]}
    ]
  }
}
```

`~/.codex/config.toml` still matters, but it holds no hook definitions. It carries the feature
gate and a `[hooks.state]` table of trust hashes — and every one of those hash keys points AT
`~/.codex/hooks.json`, which is the measurement that settles the question.

The legacy `notify` key stays a `config.toml` root key:

```toml
# ~/.codex/config.toml — root keys must precede any table
notify = ["/usr/local/bin/coffeebar-hook", "--tool=codex", "--legacy-notify"]
```

Notes that will cost time if missed:
- The engine is gated behind a `[features]` flag, and the key is **`hooks = true`**. Measured
  on 0.146.0. A longer `codex_`-prefixed spelling of that key is still in circulation in
  third-party write-ups and is wrong for this build. Without the flag hooks are silent
  no-ops. Detect and prompt rather than writing the flag silently.
- `notify` is **ignored in project-local `.codex/config.toml`** and only honoured at user
  scope. Write to `~/.codex/config.toml` only.
- Legacy `notify` passes its JSON as **argv[1], not stdin**, and fires only on
  `agent-turn-complete`. Handle both input paths in the shim.
- Codex `PreToolUse` historically intercepts the shell tool only. Do not build state inference
  that assumes file-edit tool coverage.

#### Cursor — `hooks.json`

`~/.cursor/hooks.json`, `{"version": 1, "hooks": {...}}`, command handlers, JSON over stdio
(cursor.com/docs/hooks). Relevant events: `beforeShellExecution`, `afterShellExecution`,
`beforeSubmitPrompt`, `afterFileEdit`, `stop`, `subagentStart`, `subagentStop`,
`afterAgentResponse`.

Cursor has no permission-prompt event equivalent to Claude's `Notification/permission_prompt`,
so `awaitingPermission` is not directly observable; derive `awaitingInput` from
`stop` + `afterAgentResponse` and accept lower fidelity. There are also reports that hooks fire
for the IDE but not the Cursor CLI (forum.cursor.com/t/cursor-cli-hooks/148511, 2026-01) —
verify in S4 before promising CLI support.

#### Ingest contract (shim → app)

`SOCK_STREAM` UNIX socket at `~/Library/Application Support/coffee-bar/ingest.sock`,
mode `0600`, one newline-delimited JSON object per connection.

```json
{
  "v": 1,
  "tool": "codex",
  "event": "PermissionRequest",
  "session_id": "…",
  "cwd": "/Users/…/repo",
  "ts": "2026-07-27T09:12:44Z",
  "message": "approve: rm -rf build/",
  "raw": { }
}
```

Shim contract, non-negotiable: **connect with a 250 ms timeout, write, close, `exit(0)`
unconditionally.** Never block, never print to stdout (Codex and Claude both parse stdout as a
decision), never exit non-zero. A hook that hangs holds up the agent.

### 5.6 ProcGovernor

**Built in issue #14, and NOT WIRED.** `Sources/CoffeeBarPower/ProcGovernor.swift` and the
three types around it. This section describes what exists; the sketch it replaces got the
`setpriority` argument order wrong in three places.

`ProcGovernor` ships as a tested library and **no production code path calls it**.
`recover()` has no call site anywhere under `Sources/`, `demote(_:)` has one — in
`CoffeeBarGovernorHarness`, a target with no `Package.swift` product entry that only this
suite builds — and nothing reads `SettingsKey.demotableProcessNames`. So the app demotes no
process and writes no demotion journal.

**What is missing is not plumbing.** Issue #14 never specified the part that decides WHEN
coffee-bar demotes anything. No source of the frontmost application exists anywhere in
`Sources/`, and the tracked agent pids are on `AgentSession` but are not plumbed to a
policy. Wiring is therefore a design task and is tracked as separate work; the trigger
policy is the open question. Read every present-tense sentence below as a description of
the library, not of the shipped app.
`everyDocumentAboutTheGovernorSaysNothingCallsItYet` holds this paragraph against the
source, and stops asking for it as soon as a production caller exists.

`ProcGovernor` is the first thing in this repository that touches a pid it does not own.
`DemotionProbe` moves `getpid()` and nothing else, which is what makes it safe under a
crash for free: the state lives on the task that dies.

#### The two sets

The rule is one sentence, and `DemotionPolicy` is the only place it is written:

> A process may be demoted if and only if the user named it in the **demotable** set AND no
> deny rule matches it. The deny set wins over the demotable set in every case, including
> when a process is in both.

**Demotable — configurable, and empty by default.** `SettingsKey.demotableProcessNames`,
a list of process names under `UserDefaults`. Names are matched EXACTLY against the name
the kernel reports, never as a prefix or a substring: this list decides what MAY be
demoted, so a loose match widens the blast radius. An absent key reads as EMPTY and not as
"no restriction" — §2.3 makes the set opt-in only.

**Protected — a deny list nothing can override.** Nine rules, each reported under its own
`DemotionRefusal` case:

| Rule | Refuses |
|---|---|
| `systemProcess` | `pid < 100`. Stricter than "0 and 1", and implies it. |
| `foreignUID` | another user's process |
| `coffeeBarItself` | coffee-bar's own pid |
| `ownProcessGroup` | anything in coffee-bar's process group |
| `ancestor` | coffee-bar's parent chain — the user's shell and terminal session |
| `protectedName` | `DemotionPolicy.alwaysProtectedNames`, compiled in and not configurable |
| `trackedAgent` | an agent tool coffee-bar is tracking |
| `frontmostApplication` | the application the user is looking at |
| `notInDemotableSet` | everything else. The default answer. |

Ancestors are a WALK of the parent chain, not a list of shell names: the user's shell may
be any binary. `alwaysProtectedNames` is compiled in because a protected list behind a
preference fails open — an empty or unreadable value would disable the protection.

Two limits worth knowing. `proc_pidinfo(PROC_PIDTBSDINFO)` is privileged and answers
`EPERM` for another user's process, so the deny rules read `PROC_PIDT_SHORTBSDINFO`, which
answers for every process. That record carries only 15 characters of the name, so every
entry in `alwaysProtectedNames` fits inside 15 — a longer one would silently fail to match
the foreign-uid processes the list exists to protect.

The audio and camera assertion rule from the earlier sketch is **not built**. It needs a
source for those assertions that this package does not have yet.

#### Recovery is a journal a later run reads back

**DECIDED 2026-08-05, over a recommendation panel HARD-DISSENT.** There is no supervisor
process. The reason is that a supervisor is a second process to install, keep running and
keep in step — **not** privilege. A supervisor would not have needed root, and an earlier
claim that it would was wrong and was withdrawn.

`demote(pid)` runs a fixed sequence, and the order is the requirement:

1. Read the process's current state, so the restore target is measured and not assumed.
2. Refuse unless the policy allows it.
3. Refuse if the kernel will not say WHICH process it is.
4. Append the entry to the journal and `F_FULLFSYNC` it.
5. **Only then** call `setpriority`.

Steps 4 and 5 are in that order because a journal written afterwards is defeated by a
`SIGKILL` in the window between the two calls: the process is demoted, nothing on disk
names it, and no later run can undo it. This is the same ordering rule the sleep watchdog
follows (§8.2(1)).

`recover()` restores an entry only when **all four** of these hold. Each is a separate way
of promoting a process nobody asked to promote:

1. The journal names it. Nothing else is touched.
2. It is still alive.
3. It is still the SAME process. A pid is not an identity, because macOS reuses pids, so
   the journal carries the process start time as well.
4. This app set the bit. A process that already carried `EXT_DARWINBG` was put there by
   some other tool, and clearing it now is the `-B` promotion hazard.

#### The journal is a SECOND file, for a security reason

`~/Library/Application Support/coffee-bar/state/demotion-journal.json`, directory 0700 and
file 0600. **Never** the sleep journal. That file is root-owned, and under M5 a root
process reads it and acts on it; `SECURITY.md` calls it "an instruction to a root process"
and binds four preconditions to it. Process demotion is unprivileged and same-uid, so its
journal is user-owned. Putting user-writable data into the file a root process obeys would
build exactly the instruction channel those preconditions exist to close.

The two live in different trees — `~/Library` against `/Library` — and not merely under
different names, because precondition 1 checks every component of the path.

#### The exposure this leaves

Once the governor is wired, a crash will leave every demoted process demoted **until
coffee-bar next starts**. Nothing would undo it in between, and for a long-lived process
such as a browser that can mean days. It is bounded by construction, because darwin
background state is a process attribute: it dies with the process and never survives a
reboot. It is **not solved**. Today nothing demotes anything, so nothing is exposed. See
`docs/ACCEPTED-RISKS.md`.

#### Two independent channels

Measured on macOS 26.5.2 (25F84), 2026-08-05, through `proc_pidinfo`:

| state | flags |
|---|---|
| untouched | `0x1404010` |
| after a SELF demote | `0x140c010` — sets `0x8000` |
| after an EXTERNAL demote | `0x1014010` — sets `0x10000`, clears the donor bit |

An external restore clears only the EXTERNAL bit: a process that backgrounded itself keeps
`0x8000` through `setpriority(PRIO_DARWIN_PROCESS, pid, 0)` from outside. `getpriority`
reports only the SELF channel and is blind to the other — never use it to ask about
another process.

---

## 6. UX specification

### 6.1 The default that justifies the app

**Hold `PreventUserIdleSystemSleep`, do not hold `PreventUserIdleDisplaySleep`.**

KeepingYouAwake and `caffeinate -d` keep the screen lit. An agent does not need a screen. The
panel is the largest single controllable load on a laptop, so letting it sleep while the system
stays awake is where most of the battery win comes from. Quantify this in S6 and put the
measured number in the marketing copy — it is the strongest honest claim the product has.

### 6.2 Menu bar item

- Cup glyph, fill level = battery percentage, steam = ≥1 session `working`.
- Red badge with count when any session needs attention.
- Thermometer overlay when `thermalState ≥ .serious`.
- Template image, both appearances; verify against the current macOS menu-bar rendering.

### 6.3 Popover

```
☕ coffee-bar                          🔋 62%  ·  3h 10m
────────────────────────────────────────────────────────
Serving          ● On          Profile: Espresso  ⌄
Lid-closed mode  ○ Off        (helper not installed)
────────────────────────────────────────────────────────
SESSIONS (3)
 ⚠  claude · gpu-operator        needs permission   0:04
    rm -rf build/
 ◐  codex  · nvbandwidth         working            2:31
 ✓  claude · k8s-device-plugin   done               —
────────────────────────────────────────────────────────
QUIETED (2)                                  [Aggressive]
    Slack, Notion            ← protected: Teams, Zoom
────────────────────────────────────────────────────────
Settings…                                        Quit
```

- Attention rows sort first, then `working` by elapsed descending.
- Click a session ⇒ activate the owning terminal app / Cursor window
  (`NSRunningApplication.activate`), best-effort by pid.
- Never render agent output beyond the truncated `message` field.

### 6.4 Notifications

`UNUserNotificationCenter`, one category per attention reason, with a **Focus** action.
Coalesce: at most one notification per session per 60 s; a single summary notification when
≥3 sessions need attention. Respect Focus modes — do not request time-sensitive interruption
level for anything except `failed` and lid-closed safety aborts.

### 6.5 Onboarding

Three screens, each corresponding to a permission the user must actually grant:

1. **Serve coffee** — assertion only. Works immediately, no privileges. This must be useful on
   its own; a user who stops here should still have a better KeepingYouAwake.
2. **Connect your agents** — detect installed tools, show the exact config diff, apply on
   confirm. Never write agent config without showing the diff.
3. **Lid-closed mode** — explains root, `SleepDisabled`, the thermal risk, and the revert
   guarantee. Installs the helper. Fully optional.

---

## 7. Persistence

- Config: `~/Library/Application Support/coffee-bar/config.json`, atomic write.
- Journal (crash-safe intent log): `…/state/journal.json`, written **before** each privileged
  mutation, cleared after successful revert. Owned by the daemon in
  `/Library/Application Support/coffee-bar/`.
- Telemetry (local only): SQLite via GRDB — session durations, attention latency
  (`attentionSince` → resolution), battery delta per profile. This powers a "you spent 41 min
  of battery on blocked agents this week" view, which is the app's retention hook. **Local
  only; no network egress. Ever.**

---

## 8. Safety interlocks

These are the requirements most likely to be skipped and most likely to cause harm.

### 8.1 Abort conditions

Revert to `Off` immediately, notify, and log, on any of:

- `thermalState ≥ .serious` while lid is closed (thermal is the real risk: a MacBook vents
  through the hinge area, and a closed lid under sustained agent load is the worst case).
- Battery ≤ `batteryFloor` (default 20%) on battery power.
- No session in `working` for > `idleGrace` (default 10 min) while `SleepDisabled` is set.
- Lid closed with zero registered sessions.
- User logout / shutdown / sleep request.

### 8.2 Daemon watchdog — crash-safe revert

The failure mode to engineer against: coffee-bar is `SIGKILL`ed (or crashes) with
`SleepDisabled = 1`, and the user's laptop never sleeps again.

Contract:

1. Before setting `SleepDisabled = 1`, the daemon writes `{intent: "sleepDisabled",
   setAt, ttlSeconds, priorValue}` to the journal and `fsync`s.
2. The daemon runs a 5 s timer. **No heartbeat is sent, because M5 shipped with no
   channel to send one over.** This item used to read "the app sends `heartbeat()`
   every 15 s", which assumed the XPC design that was abandoned — see `SECURITY.md`.
   Supervision on the shipped path is **TTL-only**.
3. If `now - setAt > ttl`, the daemon reverts to `priorValue`, clears the journal,
   and posts a user notification. `decide()` still carries a `.heartbeatLost`
   branch and a `heartbeatTimeout`, so a future channel needs no new policy; today
   nothing feeds them, and `WatchdogService.evaluate` substitutes `now` rather than
   reverting every armed run within one tick.
4. The daemon's launchd plist has `KeepAlive` = true and `RunAtLoad` = true. On boot it reads
   the journal; a non-empty journal means an unclean exit, so it reverts unconditionally.
5. `ttlSeconds` is hard-capped at 8 h regardless of settings.

Test this by `kill -9`-ing the arming process in CI-adjacent manual QA. It is the acceptance
criterion for M5.

### 8.3 Display safety

`SleepDisabled` alone leaves the internal panel lit under a closed lid. On entering lid-closed
mode: force display sleep, and re-verify after the lid-close event
(`NSWorkspace.screensDidSleepNotification` / `IODisplayWrangler` state). If the display is still
awake 5 s after lid close, abort the mode and notify. Do not silently cook the battery.

---

## 9. Milestones

| M | Deliverable | Acceptance criteria |
|---|---|---|
| **M0** | Capability probe CLI (`coffee-bar probe`) | Prints a JSON capability report covering S1–S6 on the target machine. No UI. |
| **M1** | Menu-bar app, assertion only | Holds/releases `PreventUserIdleSystemSleep`; display sleeps normally; `pmset -g assertions` shows coffee-bar as holder; parity with KeepingYouAwake. |
| **M2** | Claude Code adapter + SessionHub | HTTP ingest live; sessions appear/transition/disappear correctly across a 20-turn session incl. a permission prompt and a `StopFailure`; assertion auto-releases within 5 s of last `Stop`; killing coffee-bar mid-turn does not stall the agent. |
| **M3** | Codex + Cursor adapters, shim | Shim exits 0 under **every** failure mode, incl. app not running. Two separate bounds, because one number cannot cover both. **Under 50 ms** on the normal path and on every failure that answers at once — no socket, connection refused, unknown `--tool`, empty stdin — measured 9–11 ms each. **About 1 s** when a listener accepts the connection and then never answers, which is the only case that can block at all: `HookShim.totalTimeout` caps the exchange at 1 s and process start-up adds the rest, measured 1.01 s. That ceiling is a tenth of the listener's own 10 s idle timeout, so a wedged listener cannot hold the agent for its timeout on every tool call. Config diffs shown before write; both tools drive state transitions. |
| **M5** | Lid-closed mode (root CLI + launchd watchdog) | `SleepDisabled` set by `sudo coffee-bar-probe arm` and reverted by the `com.coffeebar.probewatchdog` daemon — **not** over XPC, which M5 did not build; display forced off; `kill -9` of the arming process still reverts, because the daemon and the TTL are what supervise it; reboot with a dirty journal reverts at load; all §8.1 aborts fire. |
| **M6** | Power triage + telemetry | Protected/demotable sets enforced; restore-on-exit verified; measured battery delta reported for `Espresso` vs baseline. |
| **M7** | Token Tap (§15) | OTLP receiver ingests `claude_code.token.usage` and `codex.*` token metrics; per-session and per-repo totals reconcile with `/cost` and `/status` within 2%; zero content bytes persisted; receiver refuses non-loopback binds. |

**The numbering above is the one the issues and `docs/ROADMAP.md` use: #10 is M3,
#13 is M5, #14 is M6, #15 is M7.** This table previously called lid-closed mode
M3 and power triage M5, which disagreed with both. M4 is open-source repo
hygiene; it is tracked in `docs/ROADMAP.md` and carries no acceptance row here.

Ship M1–M3 as `0.1`. M4–M5 are `0.2`. M6 is `0.3` — it is the first feature that
justifies opening the app when no agent is running.

---

## 10. Spikes — run before M2

The architecture branches on these. Each is a small standalone binary; results go in
`docs/probe-results.md` with hardware and OS build recorded.

- **S1 — `SleepDisabled` on Apple Silicon.** Set the flag, close the lid on battery with no
  external display, run a CPU load, confirm the process is still running 10 min later.
  Sources conflict (§2.2). **If this fails, the lid-closed pillar dies and the product becomes
  "attention queue + display-off + triage".** That is still shippable; know early.
- **S2 — Display state under closed lid.** With `SleepDisabled = 1`, measure whether the
  internal panel is actually powered. Determine the reliable API to force it off and keep it
  off.
- **S3 — `proc_pid_rusage` energy fields.** Confirm `RUSAGE_INFO_V4`+ availability and whether
  `ri_billed_energy` / interrupt-wakeup fields are populated for non-owned processes without
  additional entitlement.
- **S4 — Cursor CLI hooks.** Do `~/.cursor/hooks.json` handlers fire for the CLI agent, or only
  the IDE? Determines whether Cursor CLI is supported or explicitly out of scope.
- **S5 — Demotion privilege.** Does `setpriority(PRIO_DARWIN_PROCESS, pid, PRIO_DARWIN_BG)` / `/usr/sbin/taskpolicy -b -p` succeed
  on a same-uid, hardened-runtime, notarised third-party app (e.g. Slack) without root?
- **S6 — Battery measurement harness.** Reproducible protocol for measuring drain: fixed agent
  workload, fixed brightness, airplane-mode control, `ioreg -rn AppleSmartBattery` sampling.
  Every power claim in the UI must trace to a number from this harness.
- **S7 — OTLP receiver reconciliation.** Stand up a minimal OTLP/HTTP receiver, point Claude
  Code and Codex at it, run a known session, and compare the summed token counters against
  `/cost` (Claude Code) and `/status` (Codex). Anything worse than 2% means the delta/cumulative
  temporality or the double-count semantics are being handled wrong. Also confirm the Codex
  gaps in `codex exec` and `codex mcp-server` (openai/codex#12913, 2026-02) still exist.
- **S8 — Existing telemetry collision.** Determine what coffee-bar must do when the user
  already has `OTEL_EXPORTER_OTLP_ENDPOINT` set — corporate collector, managed settings, or a
  personal Grafana stack. Managed settings override user settings and cannot be displaced.
  Decide between fan-out and passive read-only mode (§15.4) with a working prototype, not on
  paper.

---

## 11. Competitive landscape

Do not ship a fourth `pmset` wrapper. As of mid-2026 the lid-closed niche is occupied:
Amphetamine (App Store), Sleepless, Wedge, LidRun, Droppy, plus AI Done Now for agent
notifications specifically. Several launched or updated May–June 2026.

coffee-bar's defensible position is the **join**: nothing in that set closes the loop from
*agent lifecycle event* → *wake policy* → *attention queue* → *power triage*. The nearest
neighbours do one leg each. Concretely, the features no competitor has:

1. Assertion lifetime bound to agent state, not a timer or a toggle.
2. Display-off-while-awake as the default (everyone else keeps the screen lit).
3. Releasing the assertion when the agent is *blocked on the human* — sleeping precisely when
   staying awake is pointless.
4. Attention latency as a first-class local metric.

If S1 fails, (1)–(4) still hold and are still differentiated. Build in that order.

---

## 12. Non-goals

Explicitly out of scope for `0.x`. Reject scope creep against this list.

- **Reading, parsing, storing, or displaying agent transcripts.** `transcript_path` and
  `~/.claude/projects/**/*.jsonl` contain proprietary source code and secrets. coffee-bar
  reads metadata only. This is a privacy commitment, not a performance one. Token accounting
  (§15) does **not** relax this: it uses the OTLP metrics stream, which carries counters and
  attributes and no content whatsoever. The transcript-parsing route to token counts is
  explicitly rejected in §15.2.
- **Any network egress.** No telemetry, no crash reporting to a third party, no update ping
  beyond the Sparkle appcast.
- **Influencing agent behaviour.** No `decision`, no `permissionDecision`, no `continue: false`.
  Observer only. A power utility that can block your tool calls is a supply-chain risk.
- **Remote control / phone notifications.** Real demand exists (Pushary et al.) but it inverts
  the trust model from local-only to networked. Separate product decision.
- **Windows / Linux.** The entire value is macOS power-management specific.
- **Boosting anything.** See §2.1.
- **Auto-answering prompts.** Never.

---

## 13. Build, signing, distribution

### 13.1 Repository layout

```
coffee-bar/
├── Package.swift                  # SwiftPM, Swift 6, strict concurrency
├── Sources/
│   ├── CoffeeBarApp/              # SwiftUI, MenuBarExtra, LSUIElement
│   ├── CoffeeBarCore/             # SessionHub, PowerBroker — pure, testable
│   ├── CoffeeBarPower/            # IOKit wrappers, libproc, thermal
│   ├── CoffeeBarHelper/           # root daemon
│   ├── CoffeeBarShim/             # coffeebar-hook executable
│   └── CoffeeBarProbe/            # M0 capability CLI
├── Tests/
├── Resources/
│   └── agent-profiles.json        # detection rules, hot-reloadable
└── docs/
    ├── probe-results.md
    └── ARCHITECTURE.md
```

`CoffeeBarCore` must have zero Apple-framework dependencies beyond Foundation so the state
machine and policy engine are testable without a Mac in the loop.

### 13.2 Concurrency

Swift 6 strict concurrency. `SessionHub` and `PowerBroker` are `actor`s. The ingest server and
the sampler are the only sources of mutation. No `@MainActor` outside the UI layer.

### 13.3 Distribution

- **Direct download only.** Developer ID + notarisation + stapling, Sparkle 2 for updates.
- Not App Store: the privileged helper, `KERN_PROCARGS2` process inspection, and writing to
  `~/.claude` are all incompatible with the sandbox. Do not attempt a sandboxed variant.
- Hardened runtime on. No `com.apple.security.get-task-allow` in release.

### 13.4 Licensing and naming

- KeepingYouAwake is MIT — inspiration is fine, but do not copy code. If any is vendored,
  reproduce the licence.
- "Claude Code", "Codex", "Cursor" are third-party marks. Nominative use only ("works with
  Claude Code"), no logos, no implied endorsement, no `claude` in the product name.
- Recommend Apache-2.0 or MIT for coffee-bar itself.

---

## 14. Testing

- **Unit:** `PowerBroker` as a pure transition table — every (profile × power source ×
  thermal × session set) combination, with abort conditions as assertions.
- **Unit:** `SessionHub` fed recorded hook payloads (capture real ones during M2; commit them
  as fixtures with paths and repo names scrubbed).
- **Integration:** a fake agent that emits the full hook event sequence, including
  out-of-order and duplicate events, and events for sessions that were never opened.
- **Fault injection:** app `SIGKILL`, daemon `SIGKILL`, socket removed mid-session, disk full
  on journal write, clock jump, ingest port already bound.
- **Manual QA matrix:** Apple Silicon on battery / on AC / lid closed / external display
  attached / Low Power Mode on. Record OS build for every run — `SleepDisabled` behaviour is
  the kind of thing Apple changes in a point release.

---

## 15. Token Tap — local token accounting

The wake assertion answers "is the agent awake?". The Token Tap answers "what did it drink?".
Same metaphor, same local-only constraint, and — importantly — a different data source from
everything above.

### 15.1 Premise audit

**"Show tokens consumed by Claude Code, Codex and Cursor" is not uniformly achievable.** The
three tools have three different levels of local observability, and the UI must reflect that
honestly rather than presenting a unified number that is silently wrong for one column.

| Tool | Local token data | Fidelity | Mechanism |
|---|---|---|---|
| Claude Code | **Yes, first-class** | per request, per model, per session, per subagent/skill/MCP | OTLP metrics |
| Codex CLI | **Yes, partial** | per turn; gaps in some entrypoints | OTLP metrics |
| Cursor | **No** | account-level only, admin-gated, no local join key | Admin REST API |

Second correction: **tokens are not cost.** `claude_code.cost.usage` is documented as an
approximation and explicitly not billing data. On a Max/Pro subscription there is no per-token
charge at all, so a dollar figure is actively misleading. Display **tokens as the primary
unit** and any currency figure as a clearly-labelled estimate, off by default.

Third: the interesting metric is not the total. Everyone's total goes up. The differentiated
metric is **cache read ratio** — `cacheRead / (input + cacheRead)` — which is the one number a
developer can act on, and which coffee-bar gets for free from the `type` attribute.

### 15.2 Two routes, and why one is rejected

**Route A — transcript parsing.** Read `~/.claude/projects/**/*.jsonl` and sum the `usage`
blocks. This is what `ccusage` and similar tools do. It works with zero configuration and
retroactively covers historical sessions.

**Rejected.** It requires opening files that contain the user's source code, prompts, and
secrets, and the transcript entry format is explicitly documented as internal to Claude Code
and subject to change between releases. Adopting it would contradict §12 and would make
coffee-bar a file that a security team has to reason about. If a user wants retroactive
history, point them at `ccusage`; do not vendor it.

**Route B — OTLP metrics receiver. Adopted.** Claude Code and Codex both ship native
OpenTelemetry exporters. Metrics carry counters and low-cardinality attributes and **no content
at all** — prompt text, responses, tool arguments and file paths live in the *logs* and *traces*
signals, which coffee-bar never enables. This is strictly better on privacy than the current
`Notification` hook body already being ingested in §5.5.

The architectural consequence: **coffee-bar contains a small embedded OTLP receiver.**
That is a bigger commitment than it sounds — see §15.5.

### 15.3 Claude Code — metrics contract

Configuration goes in the `env` block of `~/.claude/settings.json`, not the shell profile.
Environment variables must be set before `claude` launches; variables exported afterwards have
no effect, and `settings.json` is the only path that survives a new terminal tab.

```json
{
  "env": {
    "CLAUDE_CODE_ENABLE_TELEMETRY": "1",
    "OTEL_METRICS_EXPORTER": "otlp",
    "OTEL_LOGS_EXPORTER": "none",
    "OTEL_EXPORTER_OTLP_METRICS_PROTOCOL": "http/protobuf",
    "OTEL_EXPORTER_OTLP_METRICS_ENDPOINT": "http://127.0.0.1:8788/v1/metrics",
    "OTEL_METRIC_EXPORT_INTERVAL": "10000",
    "OTEL_METRICS_INCLUDE_SESSION_ID": "true",
    "OTEL_METRICS_INCLUDE_ACCOUNT_UUID": "false",
    "OTEL_METRICS_INCLUDE_RESOURCE_ATTRIBUTES": "false"
  }
}
```

Each line is load-bearing:

- `OTEL_LOGS_EXPORTER=none` — the whole privacy argument. Logs/events carry `user_prompt`,
  `tool_parameters`, `full_command`, and `file_path`. Never enable them, and never set
  `OTEL_LOG_USER_PROMPTS`, `OTEL_LOG_TOOL_DETAILS`, `OTEL_LOG_TOOL_CONTENT`, or
  `OTEL_LOG_RAW_API_BODIES`. Do not enable `CLAUDE_CODE_ENHANCED_TELEMETRY_BETA` either.
- `OTEL_METRIC_EXPORT_INTERVAL=10000` — the default is 60 s, which makes the live counter feel
  broken. 10 s is a reasonable floor; do not go below 5 s, since each export is a wakeup and
  this is a battery app.
- `OTEL_METRICS_INCLUDE_ACCOUNT_UUID=false` — suppresses `user.account_uuid` / `user.account_id`.
  There is no reason for a local menu-bar app to persist account identifiers.
  `user.email` and `organization.id` are always included when available; strip them at ingest.
- `OTEL_METRICS_INCLUDE_SESSION_ID=true` — this is the join key to §5.1's `AgentSession`.
  Without it the Token Tap cannot attribute tokens to a repo.
- Metrics-only OTLP means only the metrics-specific endpoint variable is set, so a user's
  existing generic `OTEL_EXPORTER_OTLP_ENDPOINT` for logs and traces is untouched (§15.4).

Metrics consumed:

| Metric | Unit | Use |
|---|---|---|
| `claude_code.token.usage` | tokens | The tap. Attributes: `type` ∈ {`input`, `output`, `cacheRead`, `cacheCreation`}, `model`, `query_source` ∈ {`main`, `subagent`, `auxiliary`}, `effort`, `agent.name`, `skill.name`, `mcp_server.name` |
| `claude_code.cost.usage` | USD | Estimate only, off by default |
| `claude_code.session.count` | — | Cross-check against SessionHub; also the "is telemetry working" canary |
| `claude_code.active_time.total` | s | Denominator for tokens-per-active-minute |

`query_source` is the most under-appreciated attribute here: it separates `main` from
`subagent` and `auxiliary` traffic, which is exactly the "why did that run cost so much"
breakdown. `agent.name` and `skill.name` extend it. Note that user-defined agent, skill, and
plugin names are redacted to `custom` / `third-party` unless `OTEL_LOG_TOOL_DETAILS=1`, which
coffee-bar will not set — so those buckets will legitimately show `custom`. Label them as such
in the UI rather than dropping them.

Two correctness traps:

- **Temporality.** The default is `delta`. A delta receiver accumulates by summing datapoints;
  a cumulative receiver must take the last value per series. Getting this backwards produces
  numbers that are wrong by orders of magnitude and still look plausible. Pin
  `OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE=delta` explicitly rather than relying on
  the default.
- **Version floor.** Before Claude Code v2.1.214, streams carrying usage across multiple frames
  inflated both the token and cost counters. Record `app.version` (set
  `OTEL_METRICS_INCLUDE_VERSION=true` if the cardinality cost is acceptable) and warn on known
  bad versions rather than silently reporting inflated totals.

### 15.4 Collision with existing telemetry

A meaningful fraction of the target audience — anyone at a company with an observability team,
which includes the author — already has Claude Code telemetry configured, possibly through
**managed settings that users cannot override**. coffee-bar must not break that. Three modes,
selected at onboarding after a detection pass:

1. **Own it** (no existing config): write the block in §15.3.
2. **Fan-out** (existing user-scope config): coffee-bar's receiver forwards everything it
   receives to the user's original endpoint, unchanged, and takes only the metrics signal for
   itself. Requires being careful that a coffee-bar outage does not lose the user's telemetry —
   buffer to disk and drop after a bounded window.
3. **Passive** (managed settings present, or user declines): Token Tap is disabled for that
   tool and says so plainly. Do not silently show zeros. Note that a generic
   `OTEL_EXPORTER_OTLP_ENDPOINT` in managed settings governs every signal's endpoint and strips
   lower-precedence signal-specific overrides at startup, so mode 1 is simply unavailable there.

This branch is spike S8. Do not guess.

### 15.5 The receiver

`http/protobuf` on `127.0.0.1`, path `/v1/metrics`. Requirements:

- **Bind to loopback only, and assert it.** A metrics receiver bound to `0.0.0.0` on a laptop
  that travels through airports is a security defect. Fail closed at startup if the bind
  address is not loopback.
- Port is configurable and probed for conflict; `4318` is the OTLP convention and is very
  likely already taken on this audience's machines. Default to something unused (`8788`), write
  the chosen port into the agent configs, and re-probe on launch.
- Protobuf decoding: use `swift-protobuf` with the OTLP `.proto` definitions vendored and
  pinned. Do **not** pull in the full `opentelemetry-swift` SDK — coffee-bar is a receiver, not
  an instrumented app, and the SDK brings an exporter stack it will never use.
- Accept `http/json` too. It is trivial once the schema is modelled and it makes debugging with
  `curl` possible.
- **Drop on the floor**: any `ResourceMetrics` containing a metric name not in the allow-list,
  and any attribute key not in the allow-list. Whitelist, never blacklist. If Anthropic or
  OpenAI adds a content-bearing metric attribute in a future release, coffee-bar must not
  silently start storing it.

### 15.6 Codex CLI

`[otel]` in `~/.codex/config.toml`. Two things that will otherwise waste an afternoon:

- The default `metrics_exporter` is **`statsig`, not `none`** — Codex reports anonymous usage
  to OpenAI by default and you must set the OTLP exporter explicitly to redirect metrics.
- Codex's HTTP exporter requires **signal-specific endpoint paths**; a bare host will not work.

```toml
[otel]
environment = "local"
log_user_prompt = false
exporter = "none"          # logs: off, deliberately
trace_exporter = "none"    # traces: off, deliberately

[otel.metrics_exporter.otlp-http]
endpoint = "http://127.0.0.1:8788/v1/metrics"
protocol = "binary"
```

Metrics of interest: `codex_turn_token_usage` (per-turn token counters) and
`codex_tool_call_total`, plus `codex.turn.ttft.duration_ms` for a latency panel. Resource
attribute `service.name` distinguishes `codex_cli_rs` / `codex_tui` (interactive) from
`codex_exec`.

Known gaps as of early 2026 (openai/codex#12913): `codex exec` emitted traces and logs but
**zero metrics**, and `codex mcp-server` emitted nothing at all. Re-verify in S7. If the gap
persists, `codex exec` sessions must be shown as "tokens not reported" rather than zero, and
the legacy `notify` payload (§5.5) can at least confirm the turn happened.

### 15.7 Cursor

There is no local token stream. Options, in descending order of preference:

1. **Report requests, not tokens.** Use the `hooks.json` events already ingested in §5.5 to
   count turns and tool calls, and mark the token column `—` with a tooltip explaining that
   Cursor does not expose per-session token counts locally. Honest and zero-risk.
2. **Opt-in Admin API import.** `api.cursor.com` `/teams/filtered-usage-events` returns
   `tokenUsage`, `chargedCents`, `model`, `timestamp`, `userEmail`, `isHeadless`. Requires a
   Team/Enterprise admin key, returns account-level billing rows, and — per an outstanding
   Cursor feature request (forum.cursor.com/t/…/164412) — **there is no stable join key between
   these rows and local IDE sessions**. So this gives a daily total, not per-repo attribution,
   and it violates §12's no-network-egress stance. If implemented, it must be a separate,
   explicitly-consented toggle that names the endpoint.
3. **Reading Cursor's local SQLite state to extract its auth token** and calling its private
   usage API — which is what several community extensions do. **Do not do this.** Lifting a
   credential out of another vendor's app to call an undocumented endpoint is not something
   this app should be caught doing, regardless of how well it works.

Ship (1). Offer (2) behind a switch if there is demand. Never (3).

### 15.8 Data model and retention

```swift
struct TokenSample: Codable {          // one row per receiver flush, per series
    let ts: Date
    let tool: AgentTool
    let sessionID: String?             // joins to AgentSession.sessionID
    let model: String
    let kind: TokenKind                // input | output | cacheRead | cacheCreation
    let querySource: String?           // main | subagent | auxiliary
    let attribution: String?           // agent.name / skill.name, may be "custom"
    let count: Int64
}
```

SQLite (GRDB), same store as §7. Roll up hourly after 7 days and daily after 90; default
retention 365 days, user-configurable, with a one-click purge in Settings. `sessionID` gives
repo attribution by joining to `AgentSession.repoName` — but note that `AgentSession` is
evicted on `SessionEnd`, so the repo name must be denormalised onto the first `TokenSample`
of each session or the attribution is lost.

**Never persist**: `user.email`, `user.account_uuid`, `user.account_id`, `organization.id`,
`terminal.type`, or any attribute not enumerated above. Strip at ingest, not at query time.

### 15.9 UI

A second popover tab, or a section below the session list:

```
☕ TOKEN TAP                                    Today ⌄
────────────────────────────────────────────────────────
  1.42 M tokens        cache read 87%      4h 12m active
  ▇▇▇▇▇▇▇▇▇▇▇▇▇▇▁▁▁▁▁▁▁▁▁▁  hourly, last 24h
────────────────────────────────────────────────────────
  claude   1.31 M    ▇▇▇▇▇▇▇▇▇▇▇▇▇▇▇▇▇▇▇▇▇▇▇▇
  codex      110 K   ▇▇
  cursor         —   not reported locally
────────────────────────────────────────────────────────
  BY REPO
   gpu-operator        890 K    main 71% · subagent 29%
   nvbandwidth         310 K
   k8s-device-plugin   220 K
────────────────────────────────────────────────────────
  ⓘ Counts come from each tool's own telemetry. Estimates,
    not billing.                        Export CSV · Purge
```

Design constraints:

- Tokens first, cost second and optional. If a cost figure is shown, the "estimate, not
  billing" caveat is adjacent to it, not in a settings page.
- The cache-read ratio is the headline number after the total. It is the only actionable one.
- `—` for Cursor, never `0`. Same for `codex exec` if S7 confirms the metrics gap.
- Sparkline is hourly rollup, drawn from the rollup table, not recomputed from raw samples.
- **Export CSV and Purge are first-class buttons**, not buried. A local analytics feature that
  cannot be exported or deleted in one click is a liability.

### 15.10 What this unlocks

The Token Tap is not a vanity counter; it is the thing that makes coffee-bar worth opening when
no agent is running, and it composes with the power features in ways nothing else on the market
does:

- **Tokens per watt-hour.** coffee-bar is the only process that has both the OTLP token stream
  and the `IOPowerSources` battery delta. "This session cost 1.2 M tokens and 14% of your
  battery" is a sentence no other tool can currently produce.
- **Blocked-time cost.** §5.1 already tracks `attentionSince`. Cross it with the token stream to
  surface "38 minutes of battery spent while agents waited on you" — which is the argument for
  the notification feature, quantified.
- **Cache regression alert.** A cache-read ratio that drops sharply usually means something
  changed in `CLAUDE.md` or the MCP server set. Local, no cloud, purely derived from the
  `type` attribute.

Build the first one for `0.3`. The other two are `0.4` material.

---

## 16. Open questions for Eduardo

1. **Blocked-agent policy.** Confirm the default: release the wake assertion when every session
   is `awaitingPermission`/`awaitingInput`? It is the correct energy behaviour, but a user who
   walks away and returns to a slept laptop may read it as a bug. Ship as default-on with a
   prominent toggle, or default-off?
2. **Aggressive tier.** Is `SIGSTOP` in scope at all, or is E-core demotion the floor? `SIGSTOP`
   on an Electron app will drop websockets and can lose unsent messages.
3. **Multi-machine.** Any interest in a remote-attention path, or is §12's local-only stance
   firm for `1.0`?
4. **Distribution channel.** Open source from day one (which makes the root helper auditable —
   a real trust advantage given §2.2's warnings about undocumented flags), or closed beta first?
5. **Name collision.** `coffee-bar` vs the existing crowded `pmset`-wrapper field — check
   Homebrew cask and App Store name availability before the first public commit.
6. **Embedded OTLP receiver.** It is the right design (§15.2) but it is a real dependency: a
   protobuf decoder, a bound port, and a schema that tracks two vendors. Acceptable, or would
   you rather ship `0.3` with Claude Code only via `http/json` and add protobuf later?
7. **NVIDIA context.** Your machine plausibly already exports Claude Code telemetry to a
   corporate collector, possibly via managed settings you cannot override — which puts you in
   §15.4 mode 3 on your own daily driver. Worth confirming early, because it means dogfooding
   the Token Tap needs a second profile or a personal machine.
8. **Cost display.** Given the subscription-vs-API split, does a currency figure appear at all
   in `0.3`, or is it tokens-only until there is a way to distinguish the two billing modes?
