// Runs the production SRS card shell (srsCardShellHtml + __fushiSrsSetCard) in
// real headless Chrome with card templates whose answer side fades in, and
// checks which [sound:] keys the page reports as visible (onSrsVisibleSounds).
// BUG-5353 / feedback FJXqvneRRp: the page used to judge visibility in the same
// task that inserted the card, at the entrance effect's zero frame (opacity 0),
// so a fading-in answer reported no sounds and autoplay played nothing.
// Payload (one shell + call string per case) comes from
// srs_card_visible_sounds_entrance_test.dart.
import fs from 'node:fs';
import { launchChromeDriver, resolveChrome } from '../../../tool/reader_pitch_headless/cdp_client.mjs';

if (!resolveChrome()) {
  console.log('Chrome unavailable');
  process.exit(77);
}
const payload = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));

// Records every host bridge call before the card is shown.
const stub = `
  window.__calls = [];
  window.flutter_inappwebview = { callHandler: function(name) {
    window.__calls.push([name].concat(Array.prototype.slice.call(arguments, 1)));
    return Promise.resolve(null);
  } };
`;
const prelude = `
  const fails = [];
  const check = (ok, label) => { if (!ok) fails.push(label); };
  const reports = () => window.__calls.filter((c) => c[0] === 'onSrsVisibleSounds');
  const visible = () => { const r = reports(); return r.length ? r[r.length - 1][2] : null; };
  const has = (name) => { const v = visible(); return !!v && v.indexOf(name) >= 0; };
`;
// Waits for the page's report (it comes after the face has rendered), then a
// little longer so a stray second report for the same face would show up.
const waitReport = `
  for (let i = 0; i < 150 && reports().length === 0; i++) {
    await new Promise((r) => setTimeout(r, 20));
  }
  await new Promise((r) => setTimeout(r, 300));
`;

const CASES = {
  // Whole answer block fades in with a CSS keyframe animation (from opacity 0).
  cssFade: `
    check(has('word.mp3'), 'fading-in word audio reported visible: ' + JSON.stringify(visible()));
    check(has('sent.mp3'), 'fading-in sentence audio reported visible: ' + JSON.stringify(visible()));
    check(reports().length === 1, 'one report per face: ' + reports().length);
    check(reports()[0] && reports()[0][1] === 'a|fade', 'report carries the face token: ' + JSON.stringify(reports()[0]));
  `,
  // Answer block starts at opacity 0; the card script adds a class on the next
  // tick that transitions it to 1.
  scriptTransition: `
    check(has('word.mp3'), 'script-revealed word audio reported visible: ' + JSON.stringify(visible()));
    check(has('sent.mp3'), 'script-revealed sentence audio reported visible: ' + JSON.stringify(visible()));
    check(reports().length === 1, 'one report per face: ' + reports().length);
  `,
  // Statically hidden containers stay out (HrB0STYm3E): display:none and a
  // settled opacity:0 (no animation in flight) do not leak hidden copies into
  // autoplay.
  staticHidden: `
    check(has('shown.mp3'), 'plain visible audio reported: ' + JSON.stringify(visible()));
    check(!has('none.mp3'), 'display:none copy not reported: ' + JSON.stringify(visible()));
    check(!has('clear.mp3'), 'static opacity:0 copy not reported: ' + JSON.stringify(visible()));
    check(reports().length === 1, 'one report per face: ' + reports().length);
  `,
  // HBK-AUDIT-006: an animation that only moves a hidden container while every
  // keyframe keeps opacity 0 is not a fade-in; its sound must not reach
  // autoplay / replay.
  zeroOpacityMotion: `
    check(has('shown.mp3'), 'plain visible audio reported: ' + JSON.stringify(visible()));
    check(!has('hidden_loop.mp3'), 'infinite opacity-0 motion copy not reported: ' + JSON.stringify(visible()));
    check(!has('hidden_held.mp3'), 'forwards-held opacity-0 motion copy not reported: ' + JSON.stringify(visible()));
    check(reports().length === 1, 'one report per face: ' + reports().length);
  `,
  // Reverse playback: heading toward the visible end counts, heading toward
  // the opacity-0 end (never visible again) does not.
  reverse: `
    check(has('reverse_visible.mp3'), 'reverse fade-in reported: ' + JSON.stringify(visible()));
    check(!has('reverse_hidden.mp3'), 'reverse toward opacity 0 not reported: ' + JSON.stringify(visible()));
  `,
  // Alternate: an infinite alternation comes back to visible; the final
  // return leg of a two-iteration alternation never does.
  alternate: `
    check(has('alternate_visible.mp3'), 'infinite alternate reported: ' + JSON.stringify(visible()));
    check(!has('alternate_hidden.mp3'), 'last alternate leg toward opacity 0 not reported: ' + JSON.stringify(visible()));
  `,
};

const driver = await launchChromeDriver();
let passed = 0;
try {
  for (const [name, body] of Object.entries(CASES)) {
    const page = payload[name];
    const result = await driver.evalOnPage(page.shell, `(async () => {
      ${stub}
      ${prelude}
      ${page.calls}
      ${waitReport}
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
