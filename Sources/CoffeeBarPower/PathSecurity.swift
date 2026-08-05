// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Why a path was refused as the target of a privileged read or exec.
///
/// Each caller maps these onto its own error type, so neither leaks the
/// other's vocabulary to its own callers.
enum PathSecurityError: Error, Equatable {
    case notAbsolute(String)
    case unresolvable(path: String, errno: Int32)
    case insecure(path: String, components: [InsecurePathComponent])
}

/// The one rule for "may a root process trust this path".
///
/// Two callers, deliberately. `LaunchDaemonInstaller` asks it about the program
/// launchd will exec as uid 0; `GuardedJournalReader` asks it about the journal
/// that tells a root process what to restore. Both are instructions to a root
/// process, both fail the same way, and SECURITY.md sets them the same bar — so
/// they answer to one rule rather than to two copies of it.
///
/// The precedent is `BatteryFloor.bounded`, which exists because a second clamp
/// carrying its own literals had already drifted from the first.
/// `theProgramPathAndTheJournalPathAreJudgedByTheSameRule` goes red on a split.
enum PathSecurity {
    /// `/usr/bin/true` -> `["/", "/usr", "/usr/bin", "/usr/bin/true"]`.
    ///
    /// The root directory is included: it is a component like any other, and a
    /// group-writable `/` would compromise everything below it.
    static func ancestry(of canonicalPath: String) -> [String] {
        var components = ["/"]
        var prefix = ""
        for part in canonicalPath.split(separator: "/") {
            prefix += "/" + part
            components.append(prefix)
        }
        return components
    }

    /// Resolves a path to its canonical, symlink-free form.
    ///
    /// Resolving FIRST is what makes the component walk mean anything.
    /// Checking the components of a name that still contains a symlink would
    /// validate one object and then use another, which whoever owns the link
    /// can repoint between the two.
    static func canonical(_ path: String) throws -> String {
        guard let buffer = realpath(path, nil) else {
            throw PathSecurityError.unresolvable(path: path, errno: errno)
        }
        defer { free(buffer) }
        return String(cString: buffer)
    }

    /// Every component of `path` a root process must not trust, and why.
    ///
    /// A component passes when it is owned by root — or by `requiredOwner` —
    /// and is neither group- nor other-writable. EVERY component is checked,
    /// never just the leaf: a root-owned file inside a user-writable directory
    /// can simply be replaced by rename.
    ///
    /// `requiredOwner` defaults to 0, which is the production bar and reduces
    /// this to "root-owned". It widens ONLY so a test can drive a scratch path
    /// under `NSTemporaryDirectory()`, whose upper components are root-owned
    /// and whose lower ones belong to the running user — a root-owned fixture
    /// cannot be built without root, and a security check nothing exercises is
    /// not a security check. `theGuardedReaderRequiresRootOwnershipByDefault`
    /// pins the default so that affordance cannot reach production.
    ///
    /// `path` is canonicalised here, so the components named in the result are
    /// the resolved objects rather than whatever the caller typed.
    static func insecureComponents(of path: String,
                                   requiredOwner: uid_t = 0) throws
        -> [InsecurePathComponent] {
        var insecure: [InsecurePathComponent] = []
        for component in ancestry(of: try canonical(path)) {
            var info = stat()
            // `lstat`, not `stat`: `realpath` has already removed every
            // symlink, so anything still reporting as one appeared after the
            // resolve and must not be followed.
            guard lstat(component, &info) == 0 else {
                throw PathSecurityError.unresolvable(path: component, errno: errno)
            }
            let wrongOwner = info.st_uid != 0 && info.st_uid != requiredOwner
            let writable = (info.st_mode & mode_t(S_IWGRP | S_IWOTH)) != 0
            if wrongOwner || writable {
                insecure.append(InsecurePathComponent(
                    path: component,
                    notOwnedByRoot: wrongOwner,
                    groupOrOtherWritable: writable))
            }
        }
        return insecure
    }

    /// Canonicalises `path` and returns it, or throws naming every component
    /// that failed the bar.
    static func validate(_ path: String, requiredOwner: uid_t = 0) throws -> String {
        guard path.hasPrefix("/") else {
            throw PathSecurityError.notAbsolute(path)
        }
        let resolved = try canonical(path)
        let insecure = try insecureComponents(of: resolved, requiredOwner: requiredOwner)
        guard insecure.isEmpty else {
            throw PathSecurityError.insecure(path: resolved, components: insecure)
        }
        return resolved
    }
}
