// Runs the production SRS card shell with the built-in Fushi card's definitions page
// (hybrid review rendering) in real headless Chrome and checks the host layout:
// main dictionary full width with a badge, other dictionaries in a grid, open states
// following the popup's rules. Payload is produced by srs_card_defs_layout_test.dart.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { launchChromeDriver, resolveChrome } from '../../../tool/reader_pitch_headless/cdp_client.mjs';

if (!resolveChrome()) {
  console.log('Chrome unavailable');
  process.exit(77);
}
// The Dart test writes the payload under the system temp directory; refuse anything else.
const tempRoot = fs.realpathSync(os.tmpdir());
const payloadPath = fs.realpathSync(path.resolve(process.argv[2] ?? ''));
if (path.relative(tempRoot, payloadPath).startsWith('..') || path.isAbsolute(path.relative(tempRoot, payloadPath))) {
  console.log('payload must live under ' + tempRoot);
  process.exit(2);
}
const cases = JSON.parse(fs.readFileSync(payloadPath, 'utf8'));

const driver = await launchChromeDriver();
let passed = 0;
try {
  for (const [name, page] of Object.entries(cases)) {
    const result = await driver.evalOnPage(page.shell, `(async () => {
      ${page.calls}
      const fails = [];
      const check = (ok, label) => { if (!ok) fails.push(label); };
      const root = document.getElementById('fushi-card-root');
      const fc = root.querySelector('.fc-defs-only');
      check(fc && fc.classList.contains('fushi-srs-defs-grid'), 'host layout ran');
      const more = root.querySelector('.fc-more');
      check(more && more.open, 'other dictionaries section open');
      const groups = Array.from(root.querySelectorAll('.fc-more .fc-dicts > .fc-dict'));
      const open = groups.map((g) => g.open);
      check(JSON.stringify(open) === JSON.stringify(${JSON.stringify(page.open)}),
        'open states ' + JSON.stringify(open));
      const grid = root.querySelector('.fc-more .fc-dicts');
      const tracks = getComputedStyle(grid).gridTemplateColumns.split(' ').filter(Boolean);
      check(tracks.length === ${page.cols}, 'grid columns ' + tracks.join(' '));
      const badge = root.querySelector('.fc-gloss--main .fushi-srs-main-badge');
      if (${page.main}) {
        check(!!badge, 'main badge present');
        check(badge && getComputedStyle(badge, '::before').content === '"Main"', 'badge label');
        check(badge && badge.lang === 'zh-CN', 'badge lang');
        const title = more.querySelector('.fc-more-title');
        check(title.lang === 'zh-CN', 'section title lang');
        check(getComputedStyle(title, '::before').content === '"Others"', 'section title label');
        check(getComputedStyle(more.querySelector('summary')).pointerEvents === 'none', 'section title not a toggle');
        // Main card spans the full column; each grid card is narrower.
        const mainW = root.querySelector('.fc-gloss--main').getBoundingClientRect().width;
        const cardW = groups[0].getBoundingClientRect().width;
        check(${page.cols} === 1 ? Math.abs(cardW - mainW) < 1 : cardW < mainW * 0.6, 'widths main=' + mainW + ' card=' + cardW);
      } else {
        check(more.classList.contains('fushi-srs-more--lead'), 'lead mode without main');
        check(getComputedStyle(more.querySelector('summary')).display === 'none', 'no section title without main');
        const leadW = groups[0].getBoundingClientRect().width;
        const nextW = groups[1].getBoundingClientRect().width;
        check(leadW > nextW * 1.6, 'first dictionary spans the row: ' + leadW + ' vs ' + nextW);
      }
      // Manual toggles survive a theme re-apply (same parameters).
      groups[groups.length - 1].open = !groups[groups.length - 1].open;
      const before = groups.map((g) => g.open);
      window.__fushiSrsHostLayout();
      check(JSON.stringify(groups.map((g) => g.open)) === JSON.stringify(before), 'manual toggle kept');
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
