// Runs the production SRS card shell (srsCardShellHtml + design-skin script) in
// real headless Chrome with an "eggrolls"-like imported template and checks the
// computed styles of the design-system skin (on / dark / off / toggled off).
// Payload is produced by srs_card_design_skin_test.dart.
import fs from 'node:fs';
import { launchChromeDriver, resolveChrome } from '../../../tool/reader_pitch_headless/cdp_client.mjs';

if (!resolveChrome()) {
  console.log('Chrome unavailable');
  process.exit(77);
}
const payload = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const E = payload.expect;

// Shared helpers evaluated inside the page.
const prelude = `
  const q = (sel) => document.querySelector('#fushi-card-root ' + sel);
  const cs = (sel, prop) => getComputedStyle(sel === 'body' ? document.body : q(sel))[prop];
  const fails = [];
  const check = (ok, label) => { if (!ok) fails.push(label); };
  const eq = (a, b, label) => check(a === b, label + ': ' + a + ' !== ' + b);
`;

const CASES = [
  ['light: paper / frame / serif follow the design system, saturated colors kept', 'light', `
    eq(cs('body', 'backgroundColor'), ${JSON.stringify(E.bg)}, 'body bg');
    eq(cs('.box', 'backgroundColor'), 'rgba(0, 0, 0, 0)', 'paper box is transparent');
    eq(cs('.box', 'borderTopColor'), ${JSON.stringify(E.outline)}, 'frame border');
    eq(cs('.box', 'borderTopLeftRadius'), ${JSON.stringify(E.radius)}, 'frame radius');
    eq(cs('.panel', 'backgroundColor'), ${JSON.stringify(E.surface)}, 'neutral panel');
    eq(cs('.hl', 'backgroundColor'), 'rgb(255, 213, 79)', 'highlight bg kept');
    eq(cs('.hl', 'color'), 'rgb(183, 28, 28)', 'highlight fg kept');
    eq(cs('.word', 'color'), ${JSON.stringify(E.fg)}, 'body text');
    eq(cs('.sub', 'color'), ${JSON.stringify(E.muted)}, 'grey text -> muted');
    eq(cs('a', 'color'), ${JSON.stringify(E.link)}, 'link');
    eq(cs('hr', 'borderTopColor'), ${JSON.stringify(E.outline)}, 'hr');
    check(!/Times/.test(cs('.word', 'fontFamily')), 'serif replaced: ' + cs('.word', 'fontFamily'));
    check(/monospace/.test(cs('.mono', 'fontFamily')), 'explicit font kept: ' + cs('.mono', 'fontFamily'));
    check(document.documentElement.className.indexOf('fushi-ds-measuring') < 0, 'measuring class removed');
  `],
  ['dark: dark surfaces, dark-on-paper colors toned', 'dark', `
    eq(cs('body', 'backgroundColor'), ${JSON.stringify(E.darkBg)}, 'body bg');
    eq(cs('.word', 'color'), ${JSON.stringify(E.darkFg)}, 'body text');
    check(cs('.hl', 'backgroundColor') !== 'rgb(255, 213, 79)', 'bright highlight dimmed');
    check(cs('.hl', 'color') !== 'rgb(183, 28, 28)', 'dark red text lightened');
  `],
  ['off: template renders exactly as authored (zero injection)', 'off', `
    eq(cs('body', 'backgroundColor'), 'rgb(253, 248, 236)', 'paper bg');
    eq(cs('.box', 'borderTopColor'), 'rgb(200, 200, 200)', 'grey frame');
    check(/Times/.test(cs('.word', 'fontFamily')), 'serif kept');
    eq(document.querySelectorAll('[data-fushi-ds]').length, 0, 'no skin attributes');
    eq(typeof window.__fushiSrsDesignSkin, 'undefined', 'no skin script');
    const text = Array.from(document.querySelectorAll('style')).map((s) => s.textContent).join('');
    check(text.indexOf('--fushi-ds-') < 0, 'no skin css');
  `],
  ['toggled off at runtime: restores the template look', 'light', `
    ${payload.off.theme}
    eq(cs('body', 'backgroundColor'), 'rgb(253, 248, 236)', 'paper bg back');
    eq(cs('.box', 'borderTopColor'), 'rgb(200, 200, 200)', 'grey frame back');
    eq(document.querySelectorAll('[data-fushi-ds]').length, 0, 'attributes cleared');
    check(/Times/.test(cs('.word', 'fontFamily')), 'serif back');
  `],
];

const driver = await launchChromeDriver();
let passed = 0;
try {
  for (const [name, mode, body] of CASES) {
    const page = payload[mode];
    const result = await driver.evalOnPage(page.shell, `(async () => {
      ${page.calls}
      ${prelude}
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
  // Cost of the skin pass on this card (informational, not asserted).
  for (const mode of ['off', 'light']) {
    const page = payload[mode];
    const ms = await driver.evalOnPage(page.shell, `(() => {
      ${page.calls}
      const set = ${JSON.stringify(page.calls)}.match(/window\\.__fushiSrsSetCard\\([\\s\\S]*\\);$/)[0];
      const t0 = performance.now();
      for (let i = 0; i < 200; i++) { (0, eval)(set); document.body.offsetHeight; }
      return (performance.now() - t0) / 200;
    })()`);
    console.log('setCard+layout ' + mode + ' ' + ms.toFixed(3) + ' ms');
  }
} finally {
  driver.close();
}
if (!process.exitCode) console.log('PASS ' + passed + ' browser cases');
