// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// What one waiting row is CALLED.
///
/// A caseless enum of static functions, the shape `SessionHub` and
/// `AttentionList` already use: no I/O, no clock, no stored state. It lives
/// beside them rather than in the view for the reason `AttentionList` gives —
/// the panel draws what it is handed, and what a row says is a decision a check
/// can read here with no SwiftUI and no Mac in the loop (M1 design §5.4 forbids
/// asserting on rendered AppKit text).
///
/// **The defect it replaces.** The row drew `AgentSession.repoName`, which is
/// `cwd.lastPathComponent` — the basename of whatever directory the session
/// runs in, and not the repository's name. Two rows in the maintainer's own
/// menu bar showed what that costs: a session working in
/// `…/coffee-bar/.worktrees/release-v020` read "release-v020", a worktree named
/// after a release two versions old, and "stayconnected" appeared twice with
/// nothing to tell the two sessions apart.
///
/// **Three answers, in the order a reader needs them.** `repositoryLabel` names
/// the repository from the path. `rowName` puts the tool in front of it, which
/// is the fact the row never showed and the one thing separating two agents in
/// the same checkout. `rowNames` is the only one that sees more than one
/// session, because telling two identical rows apart needs cross-row context
/// that no single-session function can have.
public enum SessionLabel {

    /// Between the tool and the repository. A middle dot, spaced.
    private static let separator = " · "

    /// How many characters of a session id a tie-break STARTS with.
    ///
    /// Eight, and it is the start rather than the answer: `distinguishingWidth`
    /// grows it until the ids in one collision really differ. A fixed eight
    /// draws two identical rows again the moment two ids share a prefix, and
    /// not every agent tool's session id is a UUID.
    private static let shortIDLength = 8

    /// The directory names a worktree is kept under, by convention.
    ///
    /// `.worktrees/` is what `rules/git-workflow.md` prescribes and `.wt/` is
    /// the sibling convention in the same toolkit. A CONVENTION, never a fact
    /// about the disk — see `repositoryLabel(for:)`.
    private static let worktreeMarkers: Set<String> = [".worktrees", ".wt"]

    /// The repository a path belongs to, with its worktree as a qualifier.
    ///
    /// **PURE STRING PARSING.** It opens nothing, resolves nothing and asks git
    /// nothing. `CoffeeBarCore` performs no I/O — design §8, held by
    /// `AppLayerBoundary_test.theCoreLayerReadsNoFilesAtAll` — which is exactly
    /// why the row reached for `lastPathComponent` in the first place. So
    /// everything below reads a CONVENTION off a string, and the limits are
    /// stated rather than hidden.
    ///
    /// **Detected**, a worktree under a one-component marker directory:
    ///
    ///     …/coffee-bar/.worktrees/release-v020         → coffee-bar [release-v020]
    ///     …/coffee-bar/.wt/hotfix-101                  → coffee-bar [hotfix-101]
    ///     …/coffee-bar/.worktrees/release-v020/Sources → coffee-bar [release-v020]
    ///     …/coffee-bar/.worktrees                      → coffee-bar
    ///
    /// The FIRST marker in the path wins, so the outermost directory is the one
    /// named as the repository. That is the real checkout in both layouts, and
    /// a worktree nested inside a worktree therefore reads as the outer one.
    ///
    /// **NOT detected.** Each of these draws its leaf directory instead, which
    /// is what the row drew before this existed:
    ///
    ///   * a TWO-component marker — `…/coffee-bar/.claude/worktrees/wf_2f1a`
    ///     reads "wf_2f1a". A real layout in this maintainer's toolkit, left
    ///     out because the brief named `.worktrees/` and `.wt/`; adding it is
    ///     one more entry and one more table row.
    ///   * a worktree checked out as a plain sibling directory —
    ///     `git worktree add ../coffee-bar-release-v020` — which carries no
    ///     marker to find.
    ///   * a session started below a repository root and outside any worktree:
    ///     `…/coffee-bar/Sources` reads "Sources". Without touching the disk a
    ///     subdirectory cannot be told from a checkout.
    ///
    /// `nil` means the path names nothing at all — "/" is the whole of that
    /// case — and the caller falls back to the session id.
    public static func repositoryLabel(for cwd: URL) -> String? {
        // Split rather than `pathComponents`: `SessionHub` builds this URL with
        // `isDirectory: true`, so the path may carry a trailing slash, and
        // omitting empty subsequences makes that — and any doubled slash —
        // irrelevant instead of leaving an empty last component.
        let parts = cwd.path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)

        // `marker > 0` because a marker with nothing before it names no
        // repository: "/.worktrees/orphan" has only the leaf to offer.
        guard let marker = parts.firstIndex(where: worktreeMarkers.contains),
              marker > 0
        else { return parts.last }

        let repository = parts[marker - 1]
        // The marker directory itself is not a name. A session sitting in
        // `…/coffee-bar/.worktrees` is in the repository and in no worktree.
        guard marker + 1 < parts.count else { return repository }
        return "\(repository) [\(parts[marker + 1])]"
    }

    /// One row's name: the tool, then what it is working on.
    ///
    /// `claude · coffee-bar`, or `claude · coffee-bar [release-v020]`.
    ///
    /// The tool comes first because it is the fact the row never carried, and
    /// it is known for CERTAIN — `AgentTool.declared(byEndpoint:)` establishes
    /// it from the endpoint the hook posted to, never from a guess about the
    /// payload.
    ///
    /// **The session-id fallback is load-bearing.** Every recorded payload
    /// carries `cwd`, but the decoder allows it to be absent and a path may
    /// name nothing, and a row with no name at all is a row the user cannot act
    /// on.
    public static func rowName(for session: AgentSession) -> String {
        let subject = session.cwd.flatMap(repositoryLabel(for:)) ?? session.sessionID
        return session.tool.displayName + separator + subject
    }

    /// A name for every session in one list, keyed by `AgentSession.id`.
    ///
    /// The ONLY function here that sees more than one session, and the only one
    /// that can: two rows reading the same thing is a property of the LIST, so
    /// `rowName(for:)` — which sees one session — could answer it only by
    /// appending an id to every row, spending a third of a 260pt row on a UUID
    /// nobody needs to read.
    ///
    /// The tie-break is the shortest prefix of the session id that really
    /// separates the colliding rows. A prefix always exists: sessions are keyed
    /// on (tool, sessionID) and the name already carries the tool, so two rows
    /// can only collide with two DIFFERENT session ids.
    ///
    /// Keyed by `id` rather than returned in order, so a caller cannot pair a
    /// name with the wrong row by re-sorting the list.
    public static func rowNames(for sessions: [AgentSession]) -> [String: String] {
        var grouped: [String: [AgentSession]] = [:]
        for session in sessions {
            grouped[rowName(for: session), default: []].append(session)
        }

        var names: [String: String] = [:]
        for (name, group) in grouped {
            guard group.count > 1 else {
                for session in group { names[session.id] = name }
                continue
            }
            let width = distinguishingWidth(of: group.map(\.sessionID))
            for session in group {
                names[session.id] = "\(name) (\(session.sessionID.prefix(width)))"
            }
        }
        return names
    }

    /// The shortest prefix length at which `ids` are all different.
    ///
    /// Starts at `shortIDLength` and grows, so the usual answer is eight
    /// characters and the unusual one is still correct. It stops at the longest
    /// id: prefixes of that length ARE the ids, so a set of distinct ids is
    /// always separated by the time the loop gets there.
    private static func distinguishingWidth(of ids: [String]) -> Int {
        let longest = ids.map(\.count).max() ?? 0
        var width = min(shortIDLength, longest)
        while width < longest, Set(ids.map { $0.prefix(width) }).count < ids.count {
            width += 1
        }
        return width
    }
}

// MARK: - What each tool is called in a row

extension AgentTool {

    /// What the panel calls this tool. Short, lowercase, one owner.
    ///
    /// On `AgentTool` and not at the call site, so the spelling is decided
    /// once: a label composed where it is drawn becomes "claudeCode" in one
    /// place and "Claude Code" in another, and adding a tool then means finding
    /// every spelling.
    ///
    /// Short and lowercase because it sits in front of a repository name in
    /// 10pt caption text, in a panel 260pt wide. "claude" rather than "claude
    /// code" for the same reason: the row has to leave room for the thing the
    /// session is actually working on.
    ///
    /// A `switch` with no `default`, as `AgentTool.ingestEndpoint` in
    /// `AgentSession.swift` already is, so adding a case to `AgentTool` fails
    /// to compile here rather than silently inheriting another tool's name.
    public var displayName: String {
        switch self {
        case .claudeCode: return "claude"
        case .codex: return "codex"
        case .cursor: return "cursor"
        }
    }
}
