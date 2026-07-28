// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Installs the watchdog as a launchd daemon.
///
/// M0 deliberately uses a plain plist plus `launchctl bootstrap system` rather
/// than `SMAppService`: it needs no app bundle, no code signing and no Xcode.
/// M5 swaps the install *mechanism* only — the journal, TTL and revert logic
/// the daemon supervises does not change.
///
/// The daemon exists because the app cannot supervise its own death. Handoff
/// §8.2(4): a boot with a dirty journal must revert unconditionally, which is
/// what `RunAtLoad` buys; a SIGKILLed watchdog must come back, which is what
/// `KeepAlive` buys. Both are load-bearing, not hygiene.
public struct LaunchDaemonInstaller {
    public static let label = "com.coffeebar.probewatchdog"
    public static let launchctlPath = "/bin/launchctl"
    public static let systemPlistURL = URL(fileURLWithPath:
        "/Library/LaunchDaemons/\(LaunchDaemonInstaller.label).plist")

    private let runner: any CommandRunning
    private let plistURL: URL

    public init(runner: any CommandRunning,
                plistURL: URL = LaunchDaemonInstaller.systemPlistURL) {
        self.runner = runner
        self.plistURL = plistURL
    }

    public func plistContents(binaryPath: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" \
        "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(Self.label)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(binaryPath)</string>
                <string>watchdog</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <true/>
            <key>ProcessType</key>
            <string>Background</string>
        </dict>
        </plist>
        """
    }

    /// Writes the plist, then hands it to launchd.
    ///
    /// The order is not incidental: `bootstrap system <path>` reads the file at
    /// that path, so the write has to land first.
    public func install(binaryPath: String) throws {
        try FileManager.default.createDirectory(
            at: plistURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data(plistContents(binaryPath: binaryPath).utf8).write(to: plistURL)
        // 0644 is a security bound, not tidiness. This file is loaded as root;
        // a group- or world-writable copy in /Library/LaunchDaemons hands root
        // to anyone who can rewrite ProgramArguments. launchd refuses to load
        // one, so a wrong mode also means no daemon at all.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644], ofItemAtPath: plistURL.path)

        let result = try runner.run(Self.launchctlPath,
                                    ["bootstrap", "system", plistURL.path])
        // `launchctl` reports failure through its exit code. Swallowing it
        // would let `install` return normally with NO daemon loaded, and `arm`
        // would then set SleepDisabled believing it is supervised — leaving
        // nothing alive to ever revert it. Throwing here is what drives
        // `arm`'s rollback path.
        guard result.exitCode == 0 else {
            throw PowerControlError.commandFailed(
                exitCode: result.exitCode, stderr: result.stderr)
        }
    }

    /// Unloads the daemon, then removes its plist.
    ///
    /// Deliberately asymmetric with `install`: the bootout failure is tolerated
    /// and the plist is removed regardless. `bootout` exits non-zero whenever
    /// nothing is loaded — the ordinary case on a second `revert` — and a
    /// `revert` that refused to finish for that reason would leave sleep
    /// disabled, which is the outcome this whole component exists to prevent.
    ///
    /// The bootout is unconditional rather than gated on the plist existing:
    /// the file can be gone while the service is still loaded, and skipping it
    /// then would strand a live root daemon that `KeepAlive` keeps restarting.
    public func uninstall() throws {
        _ = try? runner.run(Self.launchctlPath,
                            ["bootout", "system/\(Self.label)"])
        if FileManager.default.fileExists(atPath: plistURL.path) {
            try FileManager.default.removeItem(at: plistURL)
        }
    }
}
