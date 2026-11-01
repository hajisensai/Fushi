// Runs the production SRS card shell with the built-in Fushi card's definitions page
// (hybrid review rendering) in real headless Chrome and checks the host layout:
// main dictionary full width with a badge, other dictionaries packed into the shortest column like the lookup popup, open states
// following the popup's rules. Cases arrive on stdin from srs_card_defs_layout_test.dart.
import fs from 'node:fs';
import { launchChromeDriver, resolveChrome } from '../../../tool/reader_pitch_headless/cdp_client.mjs';

if (!resolveChrome()) {
  console.log('Chrome unavailable');
  process.exit(77);
}
// The Dart test pipes the cases as JSON on stdin (no file path crosses the process boundary).
const cases = JSON.parse(fs.readFileSync(0, 'utf8'));

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
      const frame0 = () => new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r)));
      const mode = ${JSON.stringify(page.mode ?? null)};
      if (mode === 'limit') {
        // 「释义显示的词典」= 前 N 本（含主词典）：截掉的不显示、不参与开合；调回全部原样回来。
        const shownNow = () => Array.from(root.querySelectorAll('.fc-more .fc-dicts > .fc-dict'))
          .filter((g) => getComputedStyle(g).display !== 'none');
        const shown = shownNow();
        const names = shown.map((g) => g.getAttribute('data-fc-dict'));
        check(JSON.stringify(names) === JSON.stringify(${JSON.stringify(page.visible ?? [])}),
          'visible dictionaries ' + JSON.stringify(names));
        check(JSON.stringify(shown.map((g) => g.open)) === JSON.stringify(${JSON.stringify(page.open)}),
          'open states ' + JSON.stringify(shown.map((g) => g.open)));
        const empty = names.length === 0;
        check((getComputedStyle(more).display === 'none') === empty, 'section hidden only when empty');
        const count = more.querySelector('.fc-more-count');
        check(!count || count.textContent === String(names.length), 'count ' + (count && count.textContent));
        const btn = more.querySelector(':scope > summary > .fushi-srs-more-toggle');
        if (btn && !empty) {
          btn.click();
          await frame0();
          const hidden = Array.from(root.querySelectorAll('.fc-more .fushi-srs-dict-over'));
          check(hidden.every((g) => !g.open || getComputedStyle(g).display === 'none'), 'expand-all ignores cut groups');
        }
        document.documentElement.style.setProperty('--fushi-srs-gloss-dicts', '0');
        window.__fushiSrsHostLayout();
        await frame0();
        check(shownNow().length === 4, 'back to all: ' + shownNow().length);
        check(getComputedStyle(more).display !== 'none', 'section back');
        check(!count || count.textContent === '4', 'count back ' + (count && count.textContent));
        return fails;
      }
      if (mode === 'main') {
        // 主词典标题行尾的收起 / 展开：显眼的按钮，一键开合主词典；主题重排不改它。
        const mainEl = root.querySelector('.fc-gloss--main');
        const mainBtn = mainEl && mainEl.querySelector('.fc-dict-label > .fushi-srs-main-toggle');
        check(!!mainBtn, 'main toggle present');
        if (!mainBtn) return fails;
        check(getComputedStyle(mainBtn).pointerEvents === 'auto', 'main toggle clickable');
        check(mainBtn.lang === 'zh-CN', 'main toggle lang');
        const mainGroups = Array.from(mainEl.querySelectorAll('.fc-dict'));
        const state = (open) => mainBtn.getAttribute('aria-expanded') === String(open) &&
          mainBtn.getAttribute('aria-label') === (open ? 'Collapse main' : 'Expand main');
        check(mainGroups.length > 0 && mainGroups.every((g) => g.open), 'main open initially');
        check(state(true), 'main toggle initial ' + mainBtn.getAttribute('aria-label'));
        const before = mainEl.getBoundingClientRect().height;
        mainBtn.click();
        await frame0();
        check(mainGroups.every((g) => !g.open), 'main collapsed');
        check(state(false), 'main toggle after collapse');
        check(mainEl.getBoundingClientRect().height < before - 20,
          'main shrinks ' + before + ' -> ' + mainEl.getBoundingClientRect().height);
        // 其他词典的开合不受影响。
        const others = Array.from(root.querySelectorAll('.fc-more .fc-dicts > .fc-dict'));
        check(JSON.stringify(others.map((g) => g.open)) === JSON.stringify(${JSON.stringify(page.open)}),
          'others untouched ' + JSON.stringify(others.map((g) => g.open)));
        window.__fushiSrsHostLayout();
        await frame0();
        check(mainGroups.every((g) => !g.open), 'collapse kept after re-layout');
        check(mainEl.querySelectorAll('.fushi-srs-main-toggle').length === 1, 'one main toggle');
        mainBtn.click();
        await frame0();
        check(mainGroups.every((g) => g.open), 'main expanded again');
        check(state(true), 'main toggle after expand');
        return fails;
      }
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

      // 模板布局键变化（卡面宽度跨过 back.html 的 720px 门槛）：模板 applyLayout 把分组全部
      // 重设开合；无论它与宿主谁先跑，最终都要回到宿主规则（逐本折叠 / 显式展开 / 自动展开）。
      const frame = () => new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r)));
      const setWide = (wide) => {
        for (const el of [document.body, ...document.querySelectorAll('.card')]) {
          el.classList.toggle('fushi-srs-layout-wide', wide);
          el.classList.toggle('fushi-srs-layout-narrow', !wide);
        }
        window.dispatchEvent(new Event('resize'));
      };
      setWide(false);
      await frame();
      setWide(true);
      await frame();
      check(JSON.stringify(groups.map((g) => g.open)) === JSON.stringify(${JSON.stringify(page.open)}),
        'open states after template layout key change ' + JSON.stringify(groups.map((g) => g.open)));
      checkPacking('after key change');

      // 主题变化会重跑宿主脚本：观察器是单例，一次尺寸变化只重排一次。
      ${page.host}
      window.__fushiSrsHostLayout();
      await frame();
      const realApply = window.__fushiSrsHostLayout;
      let applies = 0;
      window.__fushiSrsHostLayout = () => { applies++; realApply(); };
      // ResizeObserver 默认看 content box：撑高内容区（padding 不算）。
      groups[0].style.minHeight = (groups[0].offsetHeight + 40) + 'px';
      await frame();
      await new Promise((r) => setTimeout(r, 50));
      check(applies === 1, 'resize applies after script rerun: ' + applies);
      window.__fushiSrsHostLayout = realApply;

      // 「其他词典」行尾的全部展开 / 收起：有一本没展开就全部展开，再点全部收起；
      // 点它不收起整个分区，重排后仍按最短列打包。
      const btn = more.querySelector(':scope > summary > .fushi-srs-more-toggle');
      if (${page.main}) {
        check(!!btn, 'expand-all toggle present');
        check(btn && getComputedStyle(btn).pointerEvents === 'auto', 'toggle clickable');
        const every = () => groups.every((g) => g.open);
        const none = () => groups.every((g) => !g.open);
        const syncState = (all) => btn.getAttribute('aria-expanded') === String(all) &&
          btn.getAttribute('aria-label') === (all ? 'Collapse all' : 'Expand all');
        check(syncState(every()), 'toggle state initial ' + btn.getAttribute('aria-label'));
        const wasAll = every();
        btn.click();
        await frame();
        check(more.open, 'section stays open after toggle');
        check(wasAll ? none() : every(), 'first click ' + JSON.stringify(groups.map((g) => g.open)));
        check(syncState(!wasAll), 'toggle state after first click');
        await new Promise((r) => setTimeout(r, 50));
        checkPacking('after toggle all');
        btn.click();
        await frame();
        check(wasAll ? every() : none(), 'second click ' + JSON.stringify(groups.map((g) => g.open)));
        // 逐本开合后按钮状态跟上。
        if (!wasAll) {
          groups.forEach((g) => { g.open = true; });
          await new Promise((r) => setTimeout(r, 50));
          check(syncState(true), 'toggle follows manual open');
        }
      }
      // 栏宽变了但没有 window resize（排版后纵向滚动条出现 / 消失）：分列卡片的像素宽度要跟着
      // 重排，否则与通栏主词典右缘差一条滚动条宽。
      if (${page.cols} > 1) {
        fc.style.paddingRight = '8px';
        await frame();
        await new Promise((r) => setTimeout(r, 50));
        const right = list.getBoundingClientRect().right;
        const over = Math.max(...packed.map((g) => g.getBoundingClientRect().right)) - right;
        check(over < 1, 'cards re-packed after column width change, overflow ' + over);
        fc.style.paddingRight = '';
      }
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
