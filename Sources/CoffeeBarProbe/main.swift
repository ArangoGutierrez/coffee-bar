// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

// Placeholder entry point so the `coffee-bar-probe` executable target links.
// The `run` / `arm` / `report` / `revert` verbs land in later M0 tasks.
//
// The import is load-bearing: it is the Probe -> Power edge.
import CoffeeBarPower
import Foundation

// Exit non-zero so a smoke check gating on the exit code cannot read the
// unimplemented placeholder as success. EX_USAGE (64) matches the usage-error
// convention the real CLI adopts once the verbs land.
FileHandle.standardError.write(
    Data("coffee-bar-probe: not implemented yet (M0 scaffolding)\n".utf8))
exit(64)
