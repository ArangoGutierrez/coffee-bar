// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0
//
// Run with:  node --test site/assets/bench.test.js
//
// That exact form, and never a glob or a directory. Measured on Node 26:
//
//   node --test site/assets/           -> rc=1, "Cannot find module". Broken.
//   node --test 'site/assets/*.test.js' -> rc=0 when NOTHING matches. Vacuous:
//                                          a rename silently disables the suite
//                                          and CI stays green.
//   node --test site/assets/bench.test.js -> rc=1 when the file is missing.
//
// Only the explicit path fails closed, so only the explicit path belongs in CI.
//
// WHAT THIS FILE GUARDS, AND WHAT IT CANNOT.
//
// The policy bench has two seams and they fail in different ways.
//
//   1. The TABLE could disagree with `PowerBroker.decide`. A Swift guard in
//      Tests/ walks all 24 rows against the shipped policy. Nothing here
//      re-checks that, and nothing here could: this file cannot call Swift.
//   2. The LOOKUP could read a correct table wrongly — a mis-keyed row, a
//      control read backwards, a readout naming the display assertion when the
//      display is not held. The Swift guard is blind to all of that, because it
//      never runs the JavaScript. THAT is what this file exists for.
//
// So these tests read the REAL 24 rows out of `site/index.html` and assert
// LITERAL outcomes against them. No expectation below is recomputed from the
// table; every one is written out by hand from PowerBroker.swift. A test that
// derived its expectation from the same data the code reads would pass no
// matter which row the code fetched.
//
// The page is resolved relative to THIS file, never through $HOME or the
// working directory, so the suite cannot green-light a different checkout.

import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';

import { resolve, describe } from './bench.js';

const PAGE = join(import.meta.dirname, '..', 'index.html');
const html = readFileSync(PAGE, 'utf8');

function embedded(id) {
  const m = html.match(new RegExp(`id="${id}"[^>]*>([\\s\\S]*?)</script>`));
  if (!m) throw new Error(`no <script id="${id}"> in ${PAGE}`);
  return JSON.parse(m[1]);
}

const TABLE = embedded('policy-table');
const META = embedded('policy-meta');

/// One control position per field, with the page's own defaults.
///
/// It merges and nothing else. A helper that computed any part of the expected
/// outcome would be the implementation wearing a disguise.
function st(over) {
  return {
    intent: 'auto',
    displayOptIn: false,
    power: 'ac',
    batteryPercent: null,
    sessionsActive: false,
    ...over
  };
}

// ─── Anti-vacuity ────────────────────────────────────────────────────────────
// Every test below reads TABLE. If the regex above ever stops matching, the
// array is empty and `resolve` throws everywhere, which would look like a bug
// in the module rather than a broken fixture. These two literals fail first and
// say which it is. 15 is the `batteryFloorPercent` default in
// PowerBroker.swift's `PowerInputs.init`, written here by hand on purpose.

test('the page still carries the whole key space and the real floor', () => {
  assert.equal(TABLE.length, 24);
  assert.equal(META.batteryFloorPercent, 15);
});

// ─── The battery floor, at the boundary ──────────────────────────────────────
// PowerBroker suppresses at `percent <= floor`. Exactly AT the floor is the
// off-by-one this product is most likely to get wrong, so it is tested at the
// boundary and one step either side of it.

test('on battery at exactly the floor, an explicit On is refused', () => {
  const row = resolve(st({ intent: 'serve', power: 'battery', batteryPercent: 15 }), TABLE, META);
  assert.equal(row.atOrBelowFloor, true);
  assert.equal(row.system, false);
  assert.equal(row.suppressed, true);
});

test('one point above the floor, the same On holds', () => {
  const row = resolve(st({ intent: 'serve', power: 'battery', batteryPercent: 16 }), TABLE, META);
  assert.equal(row.atOrBelowFloor, false);
  assert.equal(row.system, true);
  assert.equal(row.suppressed, false);
});

test('well below the floor, the refusal still stands', () => {
  const row = resolve(st({ intent: 'serve', power: 'battery', batteryPercent: 1 }), TABLE, META);
  assert.equal(row.atOrBelowFloor, true);
  assert.equal(row.system, false);
});

test('a low reading on AC power is not a battery floor', () => {
  // The reading alone must not suppress. Dropping the power-source half of the
  // comparison would make a plugged-in Mac at 5% refuse to hold.
  const row = resolve(st({ intent: 'serve', power: 'ac', batteryPercent: 5 }), TABLE, META);
  assert.equal(row.atOrBelowFloor, false);
  assert.equal(row.system, true);
});

test('a battery with no reading never suppresses, the way a desktop does not', () => {
  // PowerBroker: "A nil reading never suppresses: a desktop has no battery."
  // In JavaScript `null <= 20` is TRUE, so the plain comparison ships the
  // opposite of the Swift behaviour. This is the test that catches it.
  const row = resolve(st({ intent: 'serve', power: 'battery', batteryPercent: null }), TABLE, META);
  assert.equal(row.atOrBelowFloor, false);
  assert.equal(row.system, true);
});

// ─── How the three control positions rank ────────────────────────────────────

test('Off refuses to hold even while an agent is working', () => {
  const row = resolve(st({ intent: 'stop', sessionsActive: true }), TABLE, META);
  assert.equal(row.system, false);
  // Refused by the off switch, NOT by the floor. A readout that blamed the
  // battery here would be a lie about why the Mac is sleeping.
  assert.equal(row.suppressed, false);
});

test('On holds with no session at all', () => {
  const row = resolve(st({ intent: 'serve', sessionsActive: false }), TABLE, META);
  assert.equal(row.system, true);
});

test('Auto holds while an agent is working', () => {
  const row = resolve(st({ intent: 'auto', sessionsActive: true }), TABLE, META);
  assert.equal(row.system, true);
  assert.equal(row.suppressed, false);
});

test('Auto releases once every agent is waiting on you', () => {
  const row = resolve(st({ intent: 'auto', sessionsActive: false }), TABLE, META);
  assert.equal(row.system, false);
  assert.equal(row.suppressed, false);
});

// ─── The display assertion never outlives the system hold ────────────────────

test('the display is held only alongside the system hold', () => {
  const row = resolve(st({ intent: 'auto', displayOptIn: true, sessionsActive: true }), TABLE, META);
  assert.equal(row.system, true);
  assert.equal(row.displayHeld, true);
});

test('the display opt-in does not survive the battery floor', () => {
  const row = resolve(
    st({ intent: 'serve', displayOptIn: true, power: 'battery', batteryPercent: 15 }), TABLE, META);
  assert.equal(row.system, false);
  assert.equal(row.displayHeld, false);
});

test('the display opt-in does not survive Off', () => {
  const row = resolve(st({ intent: 'stop', displayOptIn: true, sessionsActive: true }), TABLE, META);
  assert.equal(row.system, false);
  assert.equal(row.displayHeld, false);
});

// ─── A missing row must be loud ──────────────────────────────────────────────
// Returning undefined would paint an empty readout, which looks like a working
// page reporting "nothing held" — the most expensive way to be wrong.

test('resolve throws when the table has no row for the state', () => {
  const short = TABLE.filter(r => !(r.intent === 'auto' && r.displayOptIn === false
    && r.atOrBelowFloor === false && r.sessionsActive === true));
  assert.equal(short.length, 23);
  assert.throws(
    () => resolve(st({ intent: 'auto', sessionsActive: true }), short, META),
    /no policy row for auto\|false\|false\|true/);
});

test('resolve throws on an intent the table does not know', () => {
  assert.throws(
    () => resolve(st({ intent: 'sideways' }), TABLE, META),
    /no policy row for sideways\|false\|false\|false/);
});

// ─── The readout ─────────────────────────────────────────────────────────────

test('the readout names only the system assertion when the display is not held', () => {
  const row = resolve(st({ intent: 'auto', sessionsActive: true }), TABLE, META);
  assert.deepEqual(describe(row, META).assertions, ['PreventUserIdleSystemSleep']);
});

test('the readout names both assertions, system first, when the display is held', () => {
  const row = resolve(st({ intent: 'auto', displayOptIn: true, sessionsActive: true }), TABLE, META);
  assert.deepEqual(describe(row, META).assertions,
    ['PreventUserIdleSystemSleep', 'PreventUserIdleDisplaySleep']);
});

test('the readout names no assertion when nothing is held', () => {
  const row = resolve(st({ intent: 'stop', displayOptIn: true, sessionsActive: true }), TABLE, META);
  assert.deepEqual(describe(row, META).assertions, []);
});

test('the suppressed note states the floor inclusively and with a percent sign', () => {
  // Both details are load-bearing. "below 15%" claims the opposite of what
  // happens at exactly 15, and the Swift guard `aBoundaryPhraseMatchesTheReal-
  // Boundary` fails the page for it. The `%` character matters too: the guards
  // match `(\d+)\s*%`, so "15 percent" in words slips past them silently.
  const row = resolve(st({ intent: 'serve', power: 'battery', batteryPercent: 15 }), TABLE, META);
  assert.equal(describe(row, META).note,
    'Nothing is held. At or below 15% on battery, coffee-bar refuses the hold, '
    + 'and the floor outranks an explicit On.');
});

test('the note takes the floor from the page and never from a literal in the module', () => {
  const row = resolve(st({ intent: 'serve', power: 'battery', batteryPercent: 15 }), TABLE, META);
  const note = describe(row, { batteryFloorPercent: 35 }).note;
  assert.match(note, /At or below 35%/);
});

test('no readout anywhere phrases the floor exclusively', () => {
  // A sweep over every row the page ships. "at or below N%" is the only
  // acceptable form; a bare "below N%" or "under N%" is the false claim.
  for (const row of TABLE) {
    const note = describe(row, META).note;
    // Case-insensitive on purpose. The note opens the sentence, so the real
    // text is "At or below", and a case-sensitive lookbehind would fail to see
    // the "at or " it is meant to forgive — the guard would then reject the
    // correct phrasing and accept nothing.
    assert.doesNotMatch(note, /(?<!at or )\b(below|under)\s*\d+\s*%/i,
      `a note phrases the floor exclusively: ${note}`);
  }
});

test('the note tells a held display from a sleeping one', () => {
  const sleeping = resolve(st({ intent: 'auto', sessionsActive: true }), TABLE, META);
  assert.equal(describe(sleeping, META).note,
    'The screen still sleeps. coffee-bar takes no display assertion unless you ask for one.');

  const lit = resolve(st({ intent: 'auto', displayOptIn: true, sessionsActive: true }), TABLE, META);
  assert.equal(describe(lit, META).note,
    'You asked for the screen, so the screen is held for exactly as long as the machine is.');
});

test('a plain release is not blamed on the battery', () => {
  const row = resolve(st({ intent: 'auto', sessionsActive: false }), TABLE, META);
  assert.equal(describe(row, META).note,
    'Nothing is held. Your Mac follows its own sleep settings.');
});
