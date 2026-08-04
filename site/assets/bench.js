// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0
//
// The policy bench on site/index.html.
//
// THIS FILE CONTAINS NO POLICY. `PowerBroker.decide` in
// Sources/CoffeeBarCore/PowerBroker.swift is the only copy of the rules that
// exists. The page embeds all 24 decision rows as JSON at `#policy-table`, and
// this module looks a row up by its four inputs and paints it. A second copy of
// the policy here would drift from the Swift original and nothing in the
// repository would catch it.
//
// The ONE thing this file computes is the battery comparison, in `resolve`
// below. That is a comparison against a number the page carries at
// `#policy-meta`. The floor itself is never written here.
//
// TWO LAYERS, AND THE SEAM BETWEEN THEM IS THE POINT.
//
//   `resolve` and `describe` are pure and touch no DOM, so `bench.test.js` can
//   run them under `node --test` with no browser and no build step. They are
//   where a mis-keyed lookup or a readout naming the wrong assertion would
//   live, and they are therefore the part that is tested.
//
//   The binding below `typeof document !== 'undefined'` is composition: it
//   reads form controls and writes text nodes. Importing this module in node
//   runs none of it.
//
// Plain ES2020, one file, no framework, no build step, no external request.
//
// DEGRADATION. The controls carry `hidden` in the markup and this module
// removes it, only after a full render has succeeded. With JavaScript off, or
// if any part of the wiring fails, the controls never appear and the visitor
// reads the same 24 rows as a real HTML table. A dead control on screen is
// worse than no control.

/// The two strings `pmset -g assertions` prints for coffee-bar's holds.
///
/// They are the IOKit assertion TYPES, from `AssertionHolder.swift`:
/// `kIOPMAssertionTypePreventUserIdleSystemSleep` and
/// `kIOPMAssertionTypePreventUserIdleDisplaySleep`.
const SYSTEM_ASSERTION = 'PreventUserIdleSystemSleep';
const DISPLAY_ASSERTION = 'PreventUserIdleDisplaySleep';

/// The decision row for one set of control positions.
///
/// `state` is `{intent, displayOptIn, power, batteryPercent, sessionsActive}`.
/// `table` is the 24 rows from `#policy-table`; `meta` is `#policy-meta`.
///
/// Throws when no row matches. A silent `undefined` would paint an empty
/// readout, and an empty readout reads as "nothing is held" — a working-looking
/// page that states the opposite of the truth is the most expensive way to be
/// wrong.
export function resolve(state, table, meta) {
  // The one computation this module is allowed. A comparison, not a rule.
  //
  // The `typeof` guard is NOT decoration. `PowerBroker` reads the battery
  // through `let percent = inputs.batteryPercent`, so a nil reading never
  // suppresses — a desktop has no battery. In JavaScript `null <= 20` is TRUE,
  // so the comparison without this guard ships the opposite of the Swift
  // behaviour for exactly that case.
  const atOrBelowFloor = state.power === 'battery'
    && typeof state.batteryPercent === 'number'
    && state.batteryPercent <= meta.batteryFloorPercent;

  for (const row of table) {
    if (row.intent === state.intent
      && row.displayOptIn === state.displayOptIn
      && row.atOrBelowFloor === atOrBelowFloor
      && row.sessionsActive === state.sessionsActive) {
      return row;
    }
  }

  throw new Error('no policy row for ' + state.intent + '|' + state.displayOptIn
    + '|' + atOrBelowFloor + '|' + state.sessionsActive);
}

/// What the readout says about one row: the assertions macOS holds, in order,
/// and one sentence of context.
///
/// `meta` is a second parameter rather than a captured constant so that the
/// floor reaches the sentence from the page and never from a literal in this
/// file. `bench.test.js` passes a different floor to prove that.
export function describe(row, meta) {
  if (row.system) {
    const assertions = [SYSTEM_ASSERTION];
    if (row.displayHeld) assertions.push(DISPLAY_ASSERTION);
    return {
      assertions,
      note: row.displayHeld
        ? 'You asked for the screen, so the screen is held for exactly as long as the machine is.'
        : 'The screen still sleeps. coffee-bar takes no display assertion unless you ask for one.'
    };
  }

  if (row.suppressed) {
    // The preposition is load-bearing. The product refuses AT the floor, not
    // merely below it, and the Swift guard `aBoundaryPhraseMatchesTheReal-
    // Boundary` fails the page for "below". The `%` character matters too: the
    // guards match `(\d+)\s*%`, so "20 percent" in words slips past silently.
    return {
      assertions: [],
      note: 'Nothing is held. At or below ' + meta.batteryFloorPercent
        + '% on battery, coffee-bar refuses the hold, '
        + 'and the floor outranks an explicit On.'
    };
  }

  return {
    assertions: [],
    note: 'Nothing is held. Your Mac follows its own sleep settings.'
  };
}

// ─────────────────────────────────────────────────────────────────────────────
// The DOM binding. Composition only — every decision above this line.
// ─────────────────────────────────────────────────────────────────────────────

/// The four phases of the illustrated session, in document order. Whether an
/// agent is working is the only input that varies across them; the other three
/// come from the controls.
const PHASES = [true, false, true, false];

const INTENT_LABEL = { stop: 'Off', auto: 'Auto', serve: 'On' };

function mount() {
  const el = id => document.getElementById(id);
  const form = el('bench-controls');
  const track = el('bench-track');
  const figure = el('bench-figure');
  const stateLine = el('bench-state');
  const holdsList = el('bench-holds');
  const noteLine = el('bench-note');
  const range = el('bench-range');
  const percentInput = el('bench-percent');
  const percentOut = el('bench-percent-out');
  const tableEl = el('policy-table');
  const metaEl = el('policy-meta');

  // Fail closed. Anything missing and the page keeps its static content.
  if (!form || !track || !figure || !stateLine || !holdsList || !noteLine
    || !range || !percentInput || !percentOut || !tableEl || !metaEl) {
    return;
  }

  let table, meta;
  try {
    table = JSON.parse(tableEl.textContent);
    meta = JSON.parse(metaEl.textContent);
  } catch (e) {
    return;
  }
  if (!Array.isArray(table) || typeof meta.batteryFloorPercent !== 'number') return;

  // Motion. The staggered release animation lives in assets/site.css behind a
  // `prefers-reduced-motion: no-preference` query. This attribute is the second
  // lock: a segment changes class on every control change, which restarts that
  // animation, so the bench states the reader's preference on the element
  // itself rather than trusting one media query to survive a future edit.
  const reduceMotion = window.matchMedia
    ? window.matchMedia('(prefers-reduced-motion: reduce)')
    : null;

  function applyMotionPreference() {
    if (reduceMotion && reduceMotion.matches) {
      track.setAttribute('data-motion', 'reduce');
    } else {
      track.removeAttribute('data-motion');
    }
  }

  function readControls() {
    const power = form.elements.power.value;
    return {
      intent: form.elements.intent.value,
      displayOptIn: form.elements.display.value === 'on',
      power,
      batteryPercent: parseInt(percentInput.value, 10),
      sessionsActive: form.elements.sessions.value === 'working'
    };
  }

  function powerPhrase(state) {
    return state.power === 'battery'
      ? 'on battery at ' + state.batteryPercent + '%'
      : 'on AC power';
  }

  function paintTrack(state) {
    const segs = track.children;
    for (let p = 0; p < segs.length && p < PHASES.length; p++) {
      const row = resolve({ ...state, sessionsActive: PHASES[p] }, table, meta);
      const names = ['seg', row.system ? 'work' : 'wait'];
      // Keep the stagger classes on the two waiting phases, as the static
      // markup ships them.
      if (p === 1) names.push('w1');
      if (p === 3) names.push('w2');
      if (PHASES[p] === state.sessionsActive) names.push('now');
      segs[p].className = names.join(' ');
    }
  }

  function trackSentence(state) {
    const working = resolve({ ...state, sessionsActive: true }, table, meta);
    const waiting = resolve({ ...state, sessionsActive: false }, table, meta);
    const opening = 'With Serving on ' + INTENT_LABEL[state.intent]
      + ' and the Mac ' + powerPhrase(state) + ', coffee-bar ';
    if (working.system && waiting.system) return opening + 'holds it unbroken as well.';
    if (!working.system && !waiting.system) return opening + 'holds nothing at all.';
    return opening + 'holds it only through the two phases where the agent is '
      + 'working, and releases it while the agent waits on you.';
  }

  function paintReadout(state, row) {
    stateLine.textContent = 'Serving is on ' + INTENT_LABEL[state.intent]
      + ', the display setting is ' + (state.displayOptIn ? 'Stays on' : 'Sleeps')
      + ', the Mac is ' + powerPhrase(state)
      + ', and ' + (state.sessionsActive
        ? 'an agent is working.'
        : 'every agent is waiting on you.');

    const readout = describe(row, meta);

    while (holdsList.firstChild) holdsList.removeChild(holdsList.firstChild);
    for (const assertion of readout.assertions) {
      const li = document.createElement('li');
      li.appendChild(document.createTextNode('macOS holds '));
      const code = document.createElement('code');
      code.textContent = assertion;
      li.appendChild(code);
      li.appendChild(document.createTextNode('.'));
      holdsList.appendChild(li);
    }
    holdsList.hidden = readout.assertions.length === 0;
    noteLine.textContent = readout.note;
  }

  function render() {
    const state = readControls();
    const row = resolve(state, table, meta);

    range.hidden = state.power !== 'battery';
    percentOut.textContent = state.batteryPercent + '%';

    paintTrack(state);
    paintReadout(state, row);
    figure.setAttribute('aria-label',
      'Two timelines across one agent session. caffeinate holds the wake '
      + 'assertion unbroken through all four phases. ' + trackSentence(state));
  }

  // Reveal the controls only once a full render has succeeded against the
  // shipped defaults. If the table is short a row, the visitor keeps the static
  // page rather than a bench that answers some questions and not others.
  try {
    render();
  } catch (e) {
    return;
  }

  applyMotionPreference();
  if (reduceMotion) {
    if (typeof reduceMotion.addEventListener === 'function') {
      reduceMotion.addEventListener('change', applyMotionPreference);
    } else if (typeof reduceMotion.addListener === 'function') {
      reduceMotion.addListener(applyMotionPreference);
    }
  }

  const rerender = () => {
    try {
      render();
    } catch (e) {
      // A control moved into a state the table does not cover. Keep the last
      // good paint rather than showing a half-updated bench.
    }
  };
  form.addEventListener('change', rerender);
  form.addEventListener('input', rerender);
  form.addEventListener('submit', event => event.preventDefault());

  form.hidden = false;
}

if (typeof document !== 'undefined') {
  mount();
}
