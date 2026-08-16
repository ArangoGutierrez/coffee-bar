// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation
import CoffeeBarCore

/// A supervisor for a job that is ALREADY supervised.
///
/// `ArmService` installs a watchdog because the CLI path has to: `sudo
/// coffee-bar-probe arm` runs, arms, and exits, so something else has to be
/// alive to put `SleepDisabled` back. The registered helper is not in that
/// position — it is a resident `launchd` job, it is the process handling the
/// arm request, and `KeepAlive` restarts it if it dies. Its first act on restart
/// is to evaluate the journal, which is the same fail-safe `RunAtLoad` buys the
/// CLI watchdog.
///
/// **Installing the other daemon from here would not merely be redundant; it
/// cannot work, and the reason is a security property rather than an
/// accident.** `LaunchDaemonInstaller` resolves its program path from
/// `Bundle.main.executablePath` and refuses any component that is not
/// root-owned or is group- or other-writable. The helper's own executable is
/// `…/CoffeeBar.app/Contents/MacOS/coffee-bar-probe`, and `/Applications` is
/// writable by `admin` — so the install throws `programPathInsecure`, and it is
/// right to. A root daemon pointed at a file another account can replace is
/// exactly the primitive `PathSecurity` exists to refuse.
/// `theRegisteredJobArmsWhereTheLaunchdInstallerCouldNot` drives both halves.
///
/// `uninstall()` is a no-op for a different reason, and it is the one that
/// would bite a user. Unregistering is a decision the USER made once, through
/// an authorisation prompt macOS presented. Tearing the registration down on
/// every revert would ask them again the next time they clicked the button.
public struct RegisteredJobSupervisor: WatchdogSupervising {
    public init() {}

    public func install() throws {}

    public func uninstall() throws {}
}

/// What the app is allowed to ask the root helper for, implemented.
///
/// **This type holds no privilege decisions of its own.** It forwards to the
/// same `ArmService` and `WatchdogService` the CLI path uses, so the TTL clamp,
/// the journal path guard, the display verification, the battery floor and the
/// thermal abort are one implementation with one set of checks. A second arming
/// path with its own rules is how two answers to "how long may a hold last"
/// come to exist.
///
/// **A peer that passed the code-signing pin is still not trusted with a
/// bound.** `ttlSeconds` arrives from another process and `JournalRecord`
/// clamps it on this side: "signed by the right team" and "not currently
/// compromised" are different claims, and only the first is what a pin
/// establishes.
public final class LidClosedHelperService: NSObject, LidClosedControl, @unchecked Sendable {
    private let armService: ArmService
    private let watchdog: WatchdogService
    private let notifier: any Notifying

    public init(armService: ArmService,
                watchdog: WatchdogService,
                notifier: any Notifying) {
        self.armService = armService
        self.watchdog = watchdog
        self.notifier = notifier
    }

    /// Answers with the hold the journal RECORDED, never the one asked for.
    ///
    /// The same rule `.arm` follows when it prints to a terminal, and for the
    /// same reason: the record clamps, so echoing the request would tell the
    /// user about a hold this daemon is not keeping.
    ///
    /// The error crosses as a STRING rather than as an `Error`. An `NSError`
    /// over XPC carries a domain, a code and a `userInfo` dictionary the app
    /// would have to decode, and every one of those is a surface for a
    /// privileged process to hand structured data to an unprivileged one. A
    /// sentence is what the window shows anyway.
    public func arm(ttlSeconds: Int, reply: @escaping @Sendable (Int, String?) -> Void) {
        do {
            reply(try armService.arm(ttlSeconds: ttlSeconds), nil)
        } catch {
            // 0 rather than the requested value: a caller that read the seconds
            // without checking the message must not be handed a number that
            // reads like a granted hold.
            reply(0, "\(error)")
        }
    }

    public func revert(reply: @escaping @Sendable (Bool, String?) -> Void) {
        do {
            reply(try watchdog.revertNow(), nil)
        } catch {
            reply(false, "\(error)")
        }
    }

    /// Publishes the endpoint and supervises, for ever.
    ///
    /// **Both halves, in this process, and the pairing is load-bearing.** A
    /// listener with no tick would arm a hold nothing ever ends; a tick with no
    /// listener is the CLI watchdog, which this job is not. §8.2(2)'s 5 s timer
    /// runs on its own thread so a long XPC call cannot delay a revert, and the
    /// listener owns the main run loop.
    ///
    /// A tick that throws must not take the daemon down — a dead watchdog
    /// supervises nothing — which is the rule `.watchdog` already follows.
    public func serveForever() -> Never {
        let ticker = Thread { [watchdog, notifier] in
            while true {
                do {
                    _ = try watchdog.evaluate(now: Date(),
                                              monotonicNow: SystemMonotonicClock.now())
                } catch {
                    notifier.notify("helper tick failed: \(error)")
                }
                Thread.sleep(forTimeInterval: 5)
            }
        }
        ticker.qualityOfService = .utility
        ticker.start()

        PrivilegedHelperEndpoint(exporting: self).resume()
        // Parks. `launchd` owns this process's lifetime from here.
        RunLoop.main.run()

        // Reached only if no input source remains, which would mean the
        // listener is gone. Exiting non-zero tells launchd the job FAILED
        // rather than completed, so `KeepAlive` restarts it — and the restart
        // re-evaluates the journal, which is what bounds a live hold.
        exit(70)   // EX_SOFTWARE
    }
}
