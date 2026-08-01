// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
@testable import CoffeeBarCore

/// Guards the README's factual claims against the constants that settle them.
///
/// **Why this file exists.** On 2026-08-01 an audit found that no test in this
/// repository could see documentation prose — `git grep README Tests` returned
/// nothing — and three false claims reached commits through a fully green suite:
///
/// 1. "Until these six hooks exist … no session event ever reaches it."
///    `HookHealth.requiredEvents` lists FIVE.
/// 2. "the staleness timeout … takes 15 minutes or more." A finished session
///    takes `blockedTimeout`, 14400 s, not the 900 s `workingTimeout`.
/// 3. "unless you turn on \"stay awake while blocked\"." No such control exists;
///    it was invented from the parameter name `holdAwakeWhileBlocked`.
///
/// **What these checks CANNOT do, stated so nobody over-trusts them.** They
/// cannot tell that a number which IS a real constant is the WRONG constant for
/// the sentence it sits in. Claim 2 quoted 900 s, a genuine `workingTimeout`
/// value, on a path that takes `blockedTimeout`. Only
/// `everyNamedConstantMatchesTheNumberBesideIt` addresses that, and only when
/// the prose names the constant in backticks. That is deliberate: naming the
/// constant is what makes the claim checkable, so the guard rewards naming it.

// MARK: - Reading the README

private struct ReadmeUnreadable: Error, CustomStringConvertible {
    let path: String
    var description: String { "cannot read the README at \(path); this guard cannot run" }
}

private func repoRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()    // …/Tests/CoffeeBarCoreTests
        .deletingLastPathComponent()    // …/Tests
        .deletingLastPathComponent()    // repo root
}

private func readmeText() throws -> String {
    let url = repoRoot().appending(path: "README.md")
    guard let text = try? String(contentsOf: url, encoding: .utf8) else {
        throw ReadmeUnreadable(path: url.path)
    }
    return text
}

/// The README with fenced blocks and inline code removed.
///
/// Claims live in PROSE. A `--max-time 5` inside the hook command is not a claim
/// about a product constant, and scanning it would produce a false positive that
/// trains the reader to ignore this guard.
private func readmeProse(_ text: String) -> String {
    var s = text.replacingOccurrences(of: "```[\\s\\S]*?```", with: " ",
                                      options: .regularExpression)
    s = s.replacingOccurrences(of: "`[^`\n]*`", with: " ",
                               options: .regularExpression)
    return s
}

private struct BadPattern: Error, CustomStringConvertible {
    let pattern: String
    var description: String {
        "the regex \(pattern) does not compile, so this guard scanned nothing"
    }
}

/// Throws rather than returning `[]` when the pattern is invalid.
///
/// Returning an empty array on a compile failure makes a BROKEN guard look like
/// a CLEAN document — the false-absence trap. An earlier draft of this file used
/// `\u{2014}`, which is Swift escape syntax and not ICU regex syntax, so the
/// duration pattern silently matched nothing and the check passed over a README
/// full of durations.
private func matches(_ pattern: String, in text: String) throws -> [[String]] {
    guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    else { throw BadPattern(pattern: pattern) }
    let ns = text as NSString
    return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { m in
        (0..<m.numberOfRanges).map { i in
            m.range(at: i).location == NSNotFound ? "" : ns.substring(with: m.range(at: i))
        }
    }
}

// MARK: - The guard cannot pass vacuously

@Test func theReadmeIsReadableAndSubstantial() throws {
    let text = try readmeText()
    // A path mis-resolution would otherwise make every check below pass on an
    // empty string. Same failure-closed shape the leak guard uses.
    #expect(text.count > 2000,
            "README is \(text.count) bytes; the checks below would pass vacuously")
}

// MARK: - Claim 1: the hook count

@Test func theReadmeHookBlockIsExactlyTheRequiredEvents() throws {
    let text = try readmeText()

    // The FIRST fenced json block is the required-hook block. The optional
    // SessionEnd snippet is a separate, later block on purpose.
    let blocks = try matches("```json\\n([\\s\\S]*?)\\n```", in: text).map { $0[1] }
    #expect(!blocks.isEmpty, "no json block found in README; the guard cannot run")
    guard let first = blocks.first else { return }

    let parsed = try JSONSerialization.jsonObject(with: Data(first.utf8))
    let hooks = (parsed as? [String: Any])?["hooks"] as? [String: Any]
    #expect(hooks != nil, "the README's first json block has no `hooks` object")
    guard let hooks else { return }

    let documented = Set(hooks.keys)
    let required = Set(HookHealth.requiredEvents)
    #expect(documented == required,
            "README hook block documents \(documented.sorted()); HookHealth.requiredEvents is \(required.sorted())")
}

@Test func theReadmeProseCountMatchesTheRequiredEventCount() throws {
    let prose = readmeProse(try readmeText())
    let words = ["three": 3, "four": 4, "five": 5, "six": 6, "seven": 7]

    let found = try matches("\\b(three|four|five|six|seven)\\b[\\s\\S]{0,20}?hooks?", in: prose)
    #expect(!found.isEmpty, "no '<number> hooks' phrase in README prose; the guard cannot run")

    let real = HookHealth.requiredEvents.count
    for m in found {
        let stated = words[m[1].lowercased()] ?? -1
        #expect(stated == real,
                "README prose says \"\(m[1]) hooks\" but HookHealth.requiredEvents has \(real)")
    }
}

// MARK: - Claim 2: numbers must be real product constants

private let productConstants: [String: Double] = [
    "workingTimeout": StalePolicy.standard.workingTimeout,
    "blockedTimeout": StalePolicy.standard.blockedTimeout,
]

private let secondsPerUnit: [String: Double] = ["second": 1, "minute": 60, "hour": 3600]

@Test func everyDurationTheReadmeStatesIsARealProductConstant() throws {
    let prose = readmeProse(try readmeText())
    let known = Set(productConstants.values)

    let found = try matches("(\\d[\\d,_]*)[\\s-]*(second|minute|hour)s?", in: prose)
    #expect(!found.isEmpty, "no duration in README prose; the guard cannot run")

    for m in found {
        let digits = m[1].replacingOccurrences(of: ",", with: "")
                         .replacingOccurrences(of: "_", with: "")
        guard let value = Double(digits),
              let scale = secondsPerUnit[m[2].lowercased()] else { continue }
        let seconds = value * scale
        #expect(known.contains(seconds),
                "README states \"\(m[0])\" = \(Int(seconds)) s, which is not a product constant. Known: \(known.sorted().map { Int($0) })")
    }
}

@Test func everyNamedConstantMatchesTheNumberBesideIt() throws {
    let text = try readmeText()

    // `blockedTimeout` — 14400 seconds  ->  the number must be THAT constant,
    // not merely some real constant. This is the check that catches quoting a
    // genuine value against the wrong path.
    for (name, expected) in productConstants {
        let found = try matches("`\(name)`[^\\n]{0,40}?(\\d[\\d,_]*)\\s*(second|minute|hour)s?",
                            in: text)
        for m in found {
            let digits = m[1].replacingOccurrences(of: ",", with: "")
                             .replacingOccurrences(of: "_", with: "")
            guard let value = Double(digits),
                  let scale = secondsPerUnit[m[2].lowercased()] else { continue }
            #expect(value * scale == expected,
                    "README puts \(m[1]) \(m[2])s beside `\(name)`, but that constant is \(Int(expected)) s")
        }
    }
}

@Test func theBatteryFloorTheReadmeStatesIsTheRealDefault() throws {
    let prose = readmeProse(try readmeText())
    let found = try matches("(\\d+)\\s*%", in: prose)
    #expect(!found.isEmpty, "no percentage in README prose; the guard cannot run")

    // `batteryFloorPercent` is NOT passed, so the DEFAULT decides. Passing the
    // README's own number as the floor would make this tautological.
    for m in found {
        guard let stated = Int(m[1]) else { continue }

        let atFloor = PowerBroker.decide(PowerInputs(powerSource: .battery,
                                                     batteryPercent: stated,
                                                     userIntent: .serve))
        #expect(atFloor.idleSleepAssertion == false,
                "README claims a \(stated)% floor, but a serve at \(stated)% still holds")

        let aboveFloor = PowerBroker.decide(PowerInputs(powerSource: .battery,
                                                        batteryPercent: stated + 1,
                                                        userIntent: .serve))
        #expect(aboveFloor.idleSleepAssertion == true,
                "README claims a \(stated)% floor, but a serve at \(stated + 1)% does not hold")
    }
}

// MARK: - Claim 3: a named control must exist in the product

@Test func everyControlTheReadmeNamesExistsInTheProduct() throws {
    let prose = readmeProse(try readmeText())

    // A quoted phrase in a sentence that offers it as something the reader can
    // operate. "unless you turn on \"stay awake while blocked\"" is the shape
    // that shipped a control existing in no build.
    let controlVerbs = "(?:turn on|turn off|enable|disable|toggle|switch on|switch off|tick|check)"
    let found = try matches(controlVerbs + "[^\\n\"]{0,40}\"([^\"\\n]{4,60})\"", in: prose)

    for m in found {
        let phrase = m[1]
        #expect(sourcesContain(phrase),
                "README offers a control named \"\(phrase)\", but no file under Sources/ contains that string")
    }
}

/// True when any `.swift` file under `Sources/` contains `phrase` verbatim.
private func sourcesContain(_ phrase: String) -> Bool {
    let sources = repoRoot().appending(path: "Sources")
    guard let walker = FileManager.default.enumerator(atPath: sources.path) else { return false }
    for case let rel as String in walker where rel.hasSuffix(".swift") {
        let url = sources.appending(path: rel)
        if let body = try? String(contentsOf: url, encoding: .utf8), body.contains(phrase) {
            return true
        }
    }
    return false
}
