// Runs the production SRS card shell (srsCardShellHtml + the translation-blur
// host script + the real Fushi card template CSS + the card lookup script) in
// real headless Chrome and drives taps / hover / keys through the same DOM
// listeners the WebView uses. Payload is produced by
// srs_card_translation_blur_test.dart.
import fs from 'node:fs';
import { launchChromeDriver, resolveChrome } from '../../../tool/reader_pitch_headless/cdp_client.mjs';

if (!resolveChrome()) {
  console.log('Chrome unavailable');
  process.exit(77);
}
const P = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const settle = P.durationMs + 120;

const prelude = `
  const fails = [];
  const check = (ok, label) => { if (!ok) fails.push(label); };
  const eq = (a, b, label) => check(a === b, label + ': ' + a + ' !== ' + b);
  const wait = (ms) => new Promise((r) => setTimeout(r, ms));
  const tr = () => document.querySelector('#fushi-card-root .fc-translation');
  const cs = (el) => getComputedStyle(el);
  const textPoint = () => {
    const r = document.createRange();
    r.selectNodeContents(tr().firstChild);
    const b = r.getClientRects()[0];
    return [b.left + Math.min(20, b.width / 2), b.top + b.height / 2];
  };
  const blankPoint = () => {
    const [, y] = textPoint();
    return [tr().getBoundingClientRect().right - 4, y];
  };
  const tap = ([x, y]) => {
    const target = document.elementFromPoint(x, y);
    for (const type of ['pointerdown', 'pointerup']) {
      target.dispatchEvent(new PointerEvent(type, {
        bubbles: true, cancelable: true, composed: true, clientX: x, clientY: y,
        button: 0, pointerType: 'mouse', isPrimary: true,
      }));
    }
  };
  const revealed = () => tr().classList.contains('fushi-srs-translation-revealed');
  window.__sel = [];
  window.fushiSelection = { selectText(x, y, max, hover) { window.__sel.push([x, y, !!hover]); return null; } };
  const hostSelect = ([x, y]) => (0, eval)(${JSON.stringify(P.hostSelect)}
    .replace('1234.5', String(x)).replace('6789.5', String(y)));
`;

const CASES = [
  ['blur / reveal / lookup / re-blur / keys / card change / switched off', P.shell, `
    ${P.calls}
    ${P.lookup}
    ${prelude}
    // Default: glyphs blurred (transparent + shadow), separator line untouched, a button.
    eq(cs(tr()).color, 'rgba(0, 0, 0, 0)', 'blurred glyph color');
    check(/12px/.test(cs(tr()).textShadow), 'blur shadow: ' + cs(tr()).textShadow);
    check(cs(tr()).borderTopColor !== 'rgba(0, 0, 0, 0)', 'separator kept: ' + cs(tr()).borderTopColor);
    eq(cs(tr()).cursor, 'pointer', 'blurred cursor');
    eq(tr().getAttribute('role'), 'button', 'blurred role');
    eq(tr().tabIndex, 0, 'focusable');
    eq(tr().getAttribute('aria-expanded'), 'false', 'aria collapsed');
    eq(cs(tr()).transitionDuration.split(',')[0].trim(), ${JSON.stringify(P.durationMs / 1000 + 's')}, 'motion duration');
    // Blurred: hover lookup and host-side lookup do nothing.
    const [tx, ty] = textPoint();
    document.elementFromPoint(tx, ty).dispatchEvent(new MouseEvent('mousemove', {
      bubbles: true, clientX: tx, clientY: ty, shiftKey: true }));
    hostSelect(textPoint());
    eq(window.__sel.length, 0, 'no lookup while blurred');
    // First tap reveals only.
    tap(textPoint());
    check(revealed(), 'tap reveals');
    eq(window.__sel.length, 0, 'reveal tap does not look up');
    eq(tr().getAttribute('role'), null, 'revealed is not a button');
    eq(tr().getAttribute('aria-expanded'), 'true', 'aria expanded');
    await wait(${settle});
    check(cs(tr()).color !== 'rgba(0, 0, 0, 0)', 'revealed glyph color: ' + cs(tr()).color);
    eq(cs(tr()).textShadow, 'none', 'revealed no shadow');
    check(cs(tr()).cursor !== 'pointer', 'revealed cursor not pointer');
    // Revealed: tapping text looks up (page leg and host leg), stays revealed.
    tap(textPoint());
    eq(window.__sel.length, 1, 'tap on text looks up');
    check(revealed(), 'text tap keeps it revealed');
    hostSelect(textPoint());
    eq(window.__sel.length, 2, 'host lookup on revealed text');
    // Revealed: tapping the line's blank space re-blurs, no lookup.
    tap(blankPoint());
    check(!revealed(), 'blank tap re-blurs');
    eq(window.__sel.length, 2, 'blank tap does not look up');
    // Keyboard: Enter / Space on the focused line toggle.
    tr().focus();
    tr().dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', code: 'Enter', bubbles: true, cancelable: true }));
    check(revealed(), 'Enter reveals');
    tr().dispatchEvent(new KeyboardEvent('keydown', { key: ' ', code: 'Space', bubbles: true, cancelable: true }));
    check(!revealed(), 'Space re-blurs');
    // Card change resets to blurred (and the new node is decorated).
    tap(textPoint());
    check(revealed(), 'revealed before card change');
    ${P.nextCard}
    check(!revealed(), 'new card starts blurred');
    eq(tr().getAttribute('role'), 'button', 'new card decorated');
    // Switched off at runtime: plain lookup-able text, no leftover attributes.
    ${P.offTheme}
    check(!document.body.classList.contains('fushi-srs-blur-translation'), 'class removed');
    eq(cs(tr()).color === 'rgba(0, 0, 0, 0)', false, 'off: glyphs visible');
    eq(tr().getAttribute('role'), null, 'off: no role');
    eq(tr().getAttribute('tabindex'), null, 'off: no tabindex');
    const before = window.__sel.length;
    tap(textPoint());
    eq(window.__sel.length, before + 1, 'off: first tap looks up');
  `],
  ['no lookup scope: tap still reveals and re-blurs', P.shell, `
    ${P.calls}
    ${prelude}
    tap(textPoint());
    check(revealed(), 'reveals without lookup script');
    tap(blankPoint());
    check(!revealed(), 're-blurs without lookup script');
  `],
  ['e-ink: transitions instant', P.einkShell, `
    ${P.einkCalls}
    ${prelude}
    check(document.body.classList.contains('fushi-srs-no-motion'), 'no-motion class');
    eq(cs(tr()).transitionDuration.split(',')[0].trim(), '0s', 'instant');
    tap(textPoint());
    check(cs(tr()).color !== 'rgba(0, 0, 0, 0)', 'revealed immediately: ' + cs(tr()).color);
  `],
];

const driver = await launchChromeDriver();
let passed = 0;
try {
  for (const [name, shell, body] of CASES) {
    const result = await driver.evalOnPage(shell, `(async () => {
      let fails = [];
      try {
        ${body}
        return fails;
      } catch (err) { return fails.concat(['threw: ' + err]); }
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
