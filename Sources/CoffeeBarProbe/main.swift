// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation
import CoffeeBarCore
import CoffeeBarPower

// The privileged path is a root CLI plus a launchd watchdog. There is no XPC
// and no `SMAppService`, deliberately.
//
// SECURITY.md requires an XPC peer to be pinned by Team ID and bundle ID. The
// only bundle that ships today is built from source by the Homebrew formula and
// is ad-hoc signed — measured: `Signature=adhoc`, `TeamIdentifier=not set`, and
// `codesign -R='anchor apple generic'` exits 1 — so there is no Team ID to pin
// and no certificate chain to anchor. A peer check that cannot be satisfied is
// not a weaker check, it is an absent one.
//
// The accepted cost, which nothing here papers over: the panel cannot toggle
// lid-closed mode by itself. coffee-bar prints the command and the user runs
// it. No code path in this binary elevates its own privilege.

/// What the caller asked for, after the flags are taken out.
private struct Invocation {
    var verb: ProbeVerb = .default
    var wantsJSON = false
    var ttlSeconds = ProbeVerb.defaultTTLSeconds
    /// A token that is not a verb. Carried rather than acted on, so the usage
    /// text can name it.
    var unknownVerb: String?
}

/// Parses argv.
///
/// `--ttl` consumes the token after it, which is why this is a loop rather than
/// `first(where:)`: the old form took the first argument not starting with
/// `--`, so `coffee-bar-probe --ttl 3600 arm` would have read `3600` as the
/// verb.
private func parse(_ arguments: [String]) -> Invocation {
    var invocation = Invocation()
    var index = arguments.startIndex
    var sawVerb = false

    while index < arguments.endIndex {
        let argument = arguments[index]
        switch argument {
        case "--json":
            invocation.wantsJSON = true
        case "--ttl":
            index += 1
            if index < arguments.endIndex, let seconds = Int(arguments[index]) {
                invocation.ttlSeconds = seconds
            }
        default:
            // Unknown flags are ignored, as before. A bare token is the verb.
            if !argument.hasPrefix("--"), !sawVerb {
                sawVerb = true
                if let verb = ProbeVerb(rawValue: argument) {
                    invocation.verb = verb
                } else {
                    invocation.unknownVerb = argument
                }
            }
        }
        index += 1
    }
    return invocation
}

private func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data("coffee-bar-probe: \(message)\n".utf8))
    exit(code)
}

/// Refuses a privileged verb rather than trying to acquire privilege.
///
/// Printing the command is the whole design: nothing here elevates on the
/// app's own initiative.
private func requireRoot(_ verb: ProbeVerb) {
    guard verb.requiresRoot, getuid() != 0 else { return }
    let binary = Bundle.main.executablePath ?? "coffee-bar-probe"
    fail("""
        '\(verb.rawValue)' needs root. Run:
          sudo \(binary) \(verb.rawValue)
        """, code: 77)   // EX_NOPERM
}

private let invocation = parse(Array(CommandLine.arguments.dropFirst()))

if let unknown = invocation.unknownVerb {
    FileHandle.standardError.write(Data("""
        coffee-bar-probe: no such verb '\(unknown)'

        \(ProbeVerb.usage)
        """.utf8))
    exit(64)
}

requireRoot(invocation.verb)

// One runner for every subprocess. Each executable it is handed is a compiled
// constant — `/usr/bin/pmset`, `/bin/launchctl`. No verb takes a path to run:
// `LaunchDaemonInstaller.swift:63-67` records that taking one from an argument
// made `sudo coffee-bar-probe arm` a one-line root persistence primitive.
private let runner = SystemCommandRunner()
private let notifier = StandardErrorNotifier()

private func makeWatchdogService() -> WatchdogService {
    WatchdogService(
        reader: GuardedJournalReader(),
        power: PmsetSleepDisabledController(runner: runner),
        supervisor: LaunchDaemonInstaller(runner: runner),
        notifier: notifier,
        // §8.1's thermal and battery aborts read the real machine here. The
        // battery FLOOR comes from `WatchdogPolicy.default`, whose initialiser
        // calls `BatteryFloor.bounded` — the same single rule `PowerInputs.init`
        // uses. No second, unbounded path to the floor is opened.
        environment: SystemWatchdogEnvironment())
}

// No `default`. Every verb `ProbeVerb` declares has to be handled here or this
// stops compiling, which is what stops the usage text and the dispatch drifting
// apart the way they did in v0.1.
switch invocation.verb {
case .run:
    let report = RunCommand.execute()
    if invocation.wantsJSON {
        // Deliberately not `(try? …) ?? "{}"`. That form printed valid JSON to
        // stdout and exited 0 on an encode failure: an exit-code-only consumer
        // read SUCCESS, and a downstream `jq` read a probe that had found
        // nothing. A failure must not be mistakable for either. stdout stays
        // empty so `jq` gets nothing to parse, the reason goes to stderr, and
        // the exit code carries it to everyone who reads only that.
        do {
            print(try OutputFormatter.json(report))
        } catch {
            // EX_SOFTWARE (sysexits.h): an internal failure. Not EX_USAGE (64),
            // which this binary uses for a bad verb, and not 0 — the probe
            // produced no report, which is a different thing from a report
            // whose spikes failed.
            fail("could not encode the report: \(error)", code: 70)
        }
    } else {
        print(OutputFormatter.human(report))
    }
    // Exit 0 whenever the probe itself ran. A spike reporting `fail` is a
    // finding about the machine, not a probe malfunction, and must not be
    // conflated with one.
    exit(0)

case .arm:
    let service = ArmService(
        journal: FileJournalStore(),
        // `quarantineOnRefusal: false`: arm REFUSES on a bad path rather than
        // moving anything aside. Quarantine belongs to the party that also
        // restores the setting, which is the daemon.
        reader: GuardedJournalReader(quarantineOnRefusal: false),
        power: PmsetSleepDisabledController(runner: runner),
        supervisor: LaunchDaemonInstaller(runner: runner),
        display: PmsetDisplaySleeper(runner: runner))
    do {
        try service.arm(ttlSeconds: invocation.ttlSeconds)
    } catch ArmError.journalPathRefused(let refusal) {
        // Nothing is held: the refusal lands before the first side effect.
        fail("""
            refusing to arm: the journal path is not one a root process may \
            trust: \(refusal)
            Nothing was changed.
            """, code: 78)   // EX_CONFIG
    } catch ArmError.journalVanished {
        // Already rolled back by `arm`.
        fail("""
            the journal disappeared while arming, so the arm was undone and \
            sleep restored. Nothing is held.
            """, code: 75)   // EX_TEMPFAIL
    } catch ArmError.displayStayedAwake {
        // §8.3. The mode is already rolled back by the time this is reached.
        fail("""
            the display stayed lit after it was told to sleep, so lid-closed \
            mode was aborted and sleep restored. Nothing is held.
            """, code: 75)   // EX_TEMPFAIL
    } catch {
        fail("could not arm: \(error)", code: 70)
    }
    print("armed: sleep disabled for up to \(invocation.ttlSeconds)s, watchdog installed")
    exit(0)

case .report:
    do {
        // `quarantineOnRefusal: false`: reading for a human must not move
        // the journal the daemon still needs. See GuardedJournalReader.init.
        guard let record = try GuardedJournalReader(
                quarantineOnRefusal: false).read() else {
            print("nothing armed")
            exit(0)
        }
        if invocation.wantsJSON {
            print(try OutputFormatter.json(record))
        } else {
            print("""
                armed:   \(record.intent.rawValue)
                since:   \(record.setAt)
                expires: \(record.expiry)
                restore: SleepDisabled=\(record.priorValue ? 1 : 0)
                armedBy: pid \(record.armedBy.pid), uid \(record.armedBy.uid), \
                \(record.armedBy.binaryPath)
                """)
        }
    } catch {
        fail("could not read the journal: \(error)", code: 70)
    }
    exit(0)

case .revert:
    do {
        let undone = try makeWatchdogService().revertNow()
        print(undone ? "reverted" : "nothing was armed")
    } catch {
        fail("could not revert: \(error)", code: 70)
    }
    exit(0)

case .watchdog:
    // launchd starts this with `RunAtLoad` and keeps it alive with `KeepAlive`.
    //
    // Nothing here marks the first tick as a boot, and that is the point.
    // `RunAtLoad` means this job starts whenever the plist is bootstrapped —
    // which `arm` does, every time — so "this process just started" is NOT
    // evidence that the machine rebooted. Treating it as such made `arm`
    // install a daemon whose first act was to revert `arm`: measured end state
    // was sleep held, journal deleted and the daemon booted out.
    //
    // §8.2(4) is answered inside `WatchdogService`, by comparing the journal's
    // `setAt` against `kern.boottime`. That is the question the handoff is
    // actually asking.
    //
    // `lastHeartbeat` is nil on this path and stays nil. There is no XPC
    // channel to carry one, so supervision is TTL-only — `WatchdogService`
    // documents why that is safe and why a heartbeat could never extend a hold
    // past its TTL anyway.
    let service = makeWatchdogService()
    while true {
        do {
            _ = try service.evaluate(now: Date())
        } catch {
            // A tick that failed must not take the daemon down: the next one
            // may well succeed, and a dead watchdog supervises nothing.
            notifier.notify("watchdog tick failed: \(error)")
        }
        Thread.sleep(forTimeInterval: 5)   // §8.2(2): a 5 s timer.
    }
}
