// Runs the production SRS card shell with the built-in Fushi card's definitions page
// (hybrid review rendering) in real headless Chrome and checks the host layout:
// main dictionary full width with a badge, other dictionaries packed into the shortest column like the lookup popup, open states
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
      // 与查词弹窗同一套分列：按顺序放进当前最短的一列，列内上下紧贴（展开卡后 6px、收起卡后 4px）；
      // 一列时是模板原样的分段堆叠（卡间 2px）。
      const rowGap = (g) => ${page.cols} > 1 ? (g.open ? 6 : 4) : 2;
      const list = root.querySelector('.fc-more .fc-dicts');
      const lead = !${page.main};
      const packed = groups.slice(lead ? 1 : 0);
      const columnOf = [];
      const checkPacking = (stage) => {
        const box = list.getBoundingClientRect();
        const lefts = [...new Set(packed.map((g) => Math.round(g.getBoundingClientRect().left)))]
          .sort((a, b) => a - b);
        check(lefts.length === ${page.cols}, stage + ' columns ' + lefts.join(' '));
        check((list.dataset.fushiSrsCols ?? '1') === String(${page.cols}), stage + ' cols attr');
        const start = lead ? groups[0].getBoundingClientRect().bottom - box.top + rowGap(groups[0]) : 0;
        const bottoms = lefts.map(() => start);
        let maxBottom = start;
        packed.forEach((g, i) => {
          const r = g.getBoundingClientRect();
          const c = lefts.indexOf(Math.round(r.left));
          columnOf[i] = c;
          const shortest = bottoms[c] <= Math.min(...bottoms) + 0.5;
          check(shortest && Math.abs(r.top - box.top - bottoms[c]) < 1,
            stage + ' card ' + i + ' at col ' + c + ' top ' + (r.top - box.top) + ' expected ' + bottoms.join('/'));
          maxBottom = Math.max(maxBottom, r.bottom - box.top);
          bottoms[c] = r.bottom - box.top + rowGap(g);
        });
        if (${page.cols} > 1) check(Math.abs(box.height - maxBottom) < 1, stage + ' list height ' + box.height + ' vs ' + maxBottom);
      };
      checkPacking('initial');
      const expectCols = ${JSON.stringify(page.columnOf ?? null)};
      if (expectCols) check(JSON.stringify(columnOf.slice(0, expectCols.length)) === JSON.stringify(expectCols),
        'column order ' + JSON.stringify(columnOf));
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
      checkPacking('after toggle');
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
