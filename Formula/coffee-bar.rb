# Copyright 2026 Carlos Eduardo Arango Gutierrez
# SPDX-License-Identifier: Apache-2.0

# Homebrew tap formula for the coffee-bar CLI.
#
# This installs the `coffee-bar-probe` capability probe only. The menu-bar app
# is M1 and is not distributed through this formula — see docs/ROADMAP.md.
class CoffeeBar < Formula
  desc "Capability probe for coffee-bar, the agent-aware macOS wake manager"
  homepage "https://github.com/ArangoGutierrez/coffee-bar"
  url "https://github.com/ArangoGutierrez/coffee-bar/archive/refs/tags/v0.1.0.tar.gz"
  sha256 "REPLACE_WITH_RELEASE_TARBALL_SHA256"
  license "Apache-2.0"

  livecheck do
    url :stable
    strategy :github_latest
  end

  # Package.swift declares swift-tools-version 6.0 and .swiftLanguageMode(.v6),
  # which needs the Swift 6 compiler — Xcode 16.0 is the first release carrying
  # it. Xcode 15 fails at manifest parse, so the bound is 16.0 and not 15.0.
  depends_on xcode: ["16.0", :build]
  # Implies macOS, so a bare `depends_on :macos` alongside it is redundant.
  # Sonoma matches `platforms: [.macOS(.v14)]` in Package.swift.
  depends_on macos: :sonoma

  def install
    # --disable-sandbox: SwiftPM's own sandbox cannot nest inside Homebrew's.
    # --product: builds the probe alone, skipping the AppKit menu-bar POC
    # target, which is a spike and is not installed.
    system "swift", "build", "--disable-sandbox", "-c", "release",
           "--product", "coffee-bar-probe"
    bin.install ".build/release/coffee-bar-probe"
  end

  test do
    require "json"

    # `shell_output` fails the test on a non-zero exit, which is the first
    # thing being asserted: the probe must run, not merely install.
    report = JSON.parse(shell_output("#{bin}/coffee-bar-probe --json"))

    # Pinned deliberately. A schema bump is a breaking change for anything
    # parsing the report, and a release that ships one silently should not
    # pass its own bottle test.
    assert_equal 1, report["schemaVersion"]

    # Every spike the probe knows about must appear. S1 and S2 are reported
    # `notYetRun` rather than omitted, so their absence is a real regression
    # and not an expected gap.
    ids = report["spikes"].map { |spike| spike["id"] }
    ["baseline", "S1", "S2", "S3", "S5", "S8"].each do |id|
      assert_includes ids, id
    end

    # The host stamp is why a verdict is interpretable at all: `SleepDisabled`
    # and the power APIs change across macOS point releases, so a report that
    # cannot name the build it was measured on is worthless.
    refute_empty report["host"]["osBuild"]
    refute_empty report["host"]["hardwareModel"]
  end
end
