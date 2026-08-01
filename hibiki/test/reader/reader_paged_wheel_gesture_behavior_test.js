// Executes the production paged-wheel helper with a deterministic fake clock.
const assert = require('assert');
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const readerPath = path.resolve(
  __dirname,
  '../../lib/src/pages/implementations/reader_hibiki/webview.part.dart',
);
const source = fs.readFileSync(readerPath, 'utf8');
const startMarker = '// BEGIN PAGED_WHEEL_GESTURE_HELPER';
const endMarker = '// END PAGED_WHEEL_GESTURE_HELPER';
const start = source.indexOf(startMarker);
assert.ok(start >= 0, 'missing production paged-wheel helper start marker');
const end = source.indexOf(endMarker, start);
assert.ok(end > start, 'missing production paged-wheel helper end marker');
const helper = source.substring(start + startMarker.length, end);

function makeHarness() {
  let now = 0;
  let nextTimerId = 1;
  const timers = new Map();
  const turns = [];
  let prevented = 0;

  function setTimeoutFake(fn, delay) {
    const id = nextTimerId++;
    timers.set(id, { due: now + delay, fn });
    return id;
  }
  function clearTimeoutFake(id) { timers.delete(id); }
  function advance(ms) {
    const target = now + ms;
    for (;;) {
      let selectedId = null;
      let selected = null;
      for (const [id, timer] of timers) {
        if (timer.due <= target && (!selected || timer.due < selected.due)) {
          selectedId = id;
          selected = timer;
        }
      }
      if (!selected) break;
      now = selected.due;
      timers.delete(selectedId);
      selected.fn();
    }
    now = target;
  }

  const sandbox = {
    C: { wheelPageTurnInterval: 450 },
    Math,
    setTimeout: setTimeoutFake,
    clearTimeout: clearTimeoutFake,
    window: {
      flutter_inappwebview: {
        callHandler(name, direction) {
          if (name === 'onWheelPaginate') turns.push(direction);
        },
      },
    },
  };
  vm.createContext(sandbox);
  vm.runInContext(helper, sandbox, { filename: 'paged-wheel-helper.js' });

  function wheel(deltaX, deltaY) {
    sandbox._handlePagedWheelGesture({
      deltaX,
      deltaY,
      preventDefault() { prevented += 1; },
    });
  }
  return {
    advance,
    wheel,
    turns,
    prevented: () => prevented,
  };
}

// A 1.5s momentum stream used to pass Dart's 450ms rate limiter four times.
(function momentumBurstTurnsExactlyOnce() {
  const h = makeHarness();
  for (let elapsed = 0; elapsed <= 1500; elapsed += 60) {
    h.wheel(-36, 2);
    if (elapsed < 1500) h.advance(60);
  }
  assert.deepStrictEqual(
    h.turns,
    ['backward'],
    'one physical momentum burst must emit exactly one page turn, using the dominant axis',
  );
  assert.strictEqual(h.prevented(), 26, 'every non-zero paged wheel tick must be consumed');

  // The trailing-edge timer is refreshed by every tick, so only a full quiet
  // interval unlocks the next physical gesture.
  h.advance(449);
  h.wheel(0, 40);
  assert.deepStrictEqual(h.turns, ['backward']);
  h.advance(450);
  h.wheel(0, 40);
  assert.deepStrictEqual(h.turns, ['backward', 'forward']);
})();

// Zero-delta noise is neither consumed nor converted into a page turn.
(function zeroDeltaIsIgnored() {
  const h = makeHarness();
  h.wheel(0, 0);
  assert.deepStrictEqual(h.turns, []);
  assert.strictEqual(h.prevented(), 0);
})();

// In-burst axis noise/rebound cannot reverse or duplicate the first intent.
(function burstDirectionIsLocked() {
  const h = makeHarness();
  h.wheel(1, 30);
  h.advance(100);
  h.wheel(-80, 2);
  h.advance(100);
  h.wheel(0, -60);
  assert.deepStrictEqual(h.turns, ['forward']);
})();

console.log('reader_paged_wheel_gesture_behavior_test: all assertions passed');
