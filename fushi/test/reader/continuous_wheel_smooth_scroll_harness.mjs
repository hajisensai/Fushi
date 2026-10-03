// Runs the production continuous-mode smooth wheel helper
// (kContinuousWheelScrollJs) in real headless Chrome and drives it in the
// same prepare -> try-scroll -> commit order the reader wheel listener uses.
import fs from 'node:fs';
import { launchChromeDriver, resolveChrome } from '../../../tool/reader_pitch_headless/cdp_client.mjs';

if (!resolveChrome()) {
  console.log('Chrome unavailable');
  process.exit(77);
}
const helper = JSON.parse(fs.readFileSync(process.argv[2], 'utf8')).helper;

const PAGES = {
  horizontal: '<!doctype html><meta charset="utf-8"><style>html,body{margin:0}'
    + '</style><body><div style="height:5000px;width:10px"></div>',
  verticalRl: '<!doctype html><meta charset="utf-8"><style>html,body{margin:0}'
    + 'body{writing-mode:vertical-rl;overflow-y:hidden}</style>'
    + '<body><div style="width:5000px;height:10px"></div>',
};

// Shared prelude: the helper plus a driver mirroring the listener body.
const prelude = `
(0, eval)(${JSON.stringify(helper)});
window.__frames = (n) => new Promise((done) => {
  const step = () => (n-- <= 0 ? done() : requestAnimationFrame(step));
  requestAnimationFrame(step);
});
window.__pos = (vertical) => (vertical ? window.scrollX : window.scrollY);
window.__tick = (vertical, delta, smooth) => {
  const shown = _smoothWheelPrepare(vertical, smooth);
  const before = window.__pos(vertical);
  if (vertical) window.scrollBy({left: delta, top: 0, behavior: 'auto'});
  else window.scrollBy({left: 0, top: delta, behavior: 'auto'});
  const after = window.__pos(vertical);
  const moved = Math.abs(after - before) > 1;
  const easing = _smoothWheelCommit(vertical, shown, after);
  return {moved, easing, visible: window.__pos(vertical)};
};
`;

const CASES = [
  ['mouse tick no longer jumps: eases monotonically to the target', 'horizontal', `
    const t = __tick(false, 100, true);
    check(t.moved && t.easing, 'tick accepted as easing');
    check(t.visible === 0, 'no synchronous jump (visible ' + t.visible + ')');
    await __frames(1);
    const p1 = __pos(false);
    check(p1 > 0 && p1 < 100, 'first frame is in between (' + p1 + ')');
    await __frames(3);
    const p2 = __pos(false);
    check(p2 > p1 && p2 < 100, 'keeps approaching (' + p2 + ')');
    await __frames(60);
    check(__pos(false) === 100, 'settles exactly on target (' + __pos(false) + ')');
  `],
  ['rapid ticks accumulate from the easing target', 'horizontal', `
    __tick(false, 100, true);
    __tick(false, 100, true);
    __tick(false, 100, true);
    await __frames(80);
    check(__pos(false) === 300, 'three notches = 300px (' + __pos(false) + ')');
  `],
  ['at the edge with no easing: boundary is reported (chapter turn path)', 'horizontal', `
    const max = document.documentElement.scrollHeight - innerHeight;
    window.scrollTo(0, max);
    const t = __tick(false, 100, true);
    check(!t.moved && !t.easing, 'boundary tick: not moved, not easing');
    check(__pos(false) === max, 'position unchanged');
    await __frames(5);
    check(__pos(false) === max, 'no animation started');
  `],
  ['ticks while still easing into the edge are not a boundary', 'horizontal', `
    const max = document.documentElement.scrollHeight - innerHeight;
    window.scrollTo(0, max - 50);
    const a = __tick(false, 100, true);
    check(a.moved && a.easing, 'first tick eases toward the edge');
    const b = __tick(false, 100, true);
    check(!b.moved && b.easing, 'second tick: stuck at the edge but still easing');
    await __frames(80);
    check(__pos(false) === max, 'reached the edge (' + __pos(false) + ')');
    const c = __tick(false, 100, true);
    check(!c.moved && !c.easing, 'after settling the next tick is a boundary');
  `],
  ['backward ticks clamp at the start', 'horizontal', `
    window.scrollTo(0, 30);
    const a = __tick(false, -100, true);
    check(a.moved && a.easing, 'eases back toward the start');
    await __frames(80);
    check(__pos(false) === 0, 'clamped to 0 (' + __pos(false) + ')');
  `],
  ['external scroll during easing wins (keyboard page / restore)', 'horizontal', `
    __tick(false, 600, true);
    await __frames(2);
    window.scrollTo(0, 2000);
    await __frames(40);
    check(__pos(false) === 2000, 'easing yielded to the external scroll (' + __pos(false) + ')');
  `],
  ['trackpad lands immediately and cancels a running ease', 'horizontal', `
    __tick(false, 600, true);
    await __frames(2);
    const mid = __pos(false);
    const t = __tick(false, 10, false);
    check(t.moved && !t.easing, 'trackpad tick is not eased');
    check(t.visible === mid + 10, 'trackpad moved 1:1 (' + t.visible + ' vs ' + (mid + 10) + ')');
    await __frames(40);
    check(__pos(false) === mid + 10, 'old ease no longer runs (' + __pos(false) + ')');
  `],
  ['inherited trackpad fling is swallowed until a quiet gap (BUG-2831)', 'horizontal', `
    // The document was just installed: a 1.5s momentum stream of 16ms ticks that
    // started in the previous chapter must be eaten whole, however long it runs.
    const t0 = Date.now();
    let swallowed = 0;
    for (let t = t0; t < t0 + 1500; t += 16) {
      if (_swallowInheritedTrackpadFling(t, 450)) swallowed++;
    }
    check(swallowed === Math.ceil(1500 / 16), 'whole fling swallowed (' + swallowed + ')');
    const gestureAt = t0 + 1500 + 500;
    check(!_swallowInheritedTrackpadFling(gestureAt, 450), 'new gesture after quiet passes');
    check(!_swallowInheritedTrackpadFling(gestureAt + 16, 450), 'and keeps passing');
  `],
  ['first trackpad gesture after a settled load is not swallowed', 'horizontal', `
    check(!_swallowInheritedTrackpadFling(Date.now() + 451, 450), 'quiet since install = new gesture');
  `],
  ['vertical-rl: eases along negative scrollX', 'verticalRl', `
    const t = __tick(true, -100, true);
    check(t.moved && t.easing, 'vertical tick eases');
    check(t.visible === 0, 'no synchronous jump');
    await __frames(1);
    const p = __pos(true);
    check(p < 0 && p > -100, 'in between (' + p + ')');
    await __frames(80);
    check(__pos(true) === -100, 'settles on -100 (' + __pos(true) + ')');
  `],
];

const driver = await launchChromeDriver();
let passed = 0;
try {
  for (const [name, page, body] of CASES) {
    const result = await driver.evalOnPage(PAGES[page], `(async () => {
      ${prelude}
      const fails = [];
      function check(ok, label) { if (!ok) fails.push(label); }
      try { ${body} } catch (err) { fails.push('threw: ' + err); }
      return fails;
    })()`);
    if (result.length) {
      console.log('FAIL ' + name + ': ' + result.join('; '));
      process.exitCode = 1;
    } else {
      passed++;
    }
  }
} finally {
  driver.close();
}
if (!process.exitCode) console.log('PASS ' + passed + ' browser cases');
