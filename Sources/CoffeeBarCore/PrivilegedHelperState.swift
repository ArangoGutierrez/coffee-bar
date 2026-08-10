// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// What the root helper on disk is, relative to the one this build ships.
///
/// `unverifiable` is a case rather than an optional because the caller has to
/// SAY something. An app that cannot read its own bundled probe knows less than
/// one that can, and reporting `current` there would be the same lie
/// `HookHealth` used to tell about a dead hook.
public enum PrivilegedHelperState: Equatable {
    /// Nothing at the privileged path. The install advisory covers this.
    case notInstalled
    /// Byte-identical to the bundled probe.
    case current
    /// Present and different. The user is running an older root binary.
    case stale
    /// The bundled probe could not be read, so no comparison happened.
    case unverifiable
}

public enum PrivilegedHelper {
    /// Compares the two copies by CONTENT.
    ///
    /// Byte equality rather than a version string, a modification date or a
    /// size. A date compares when the file was written and not what is in it,
    /// and `install(1)` sets a fresh one on every copy; a size collides
    /// trivially. Bytes answer the question actually being asked.
    ///
    /// Order of the checks is load-bearing. `unverifiable` is decided FIRST:
    /// without a bundled copy there is nothing to compare against, and
    /// answering `notInstalled` there would report a clean machine while the
    /// app is the broken half.
    public static func state(bundled: Data?, installed: Data?) -> PrivilegedHelperState {
        guard let bundled else { return .unverifiable }
        guard let installed else { return .notInstalled }
        return bundled == installed ? .current : .stale
    }
}
