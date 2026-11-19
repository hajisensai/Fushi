// VN 开关工具栏（setChromeInsets）不打断当前屏：真 Chrome 里的行为跑手。
// 由 vn_refit_late_image_test.dart 执行，payload（生产 VN shell + 选区脚本 + 生产 VN CSS 的
// JSON）经 stdin 送入。
//
// 修前：VN 的 setChromeInsets 写完两个变量就无条件 refitScreensToCurrentViewport()，后者
// 把整章每个可拆屏重量一遍、再 renderScreen(index, true)——清选区、清逐字显现并把整屏直接
// 补完。悬浮底栏下预留恒为 0，开关工具栏前后下发值相同也照做；首次内容就绪的补发还会把
// 正在逐字显现的首屏直接补完。
//
// 修后：
// - 下发值与已生效值相同 → 不重切、不重渲；
// - 值变了但当前屏的内容没变（短段落仍装得下，或只是前面的屏被拆多了、下标后移）→ 屏表
//   重切，屏上 DOM 与逐字显现原样保留；
// - 当前屏的内容真的变了（长段落在更矮的盒里要多拆）→ 重渲，仍从同一个字开始。
import assert from 'node:assert/strict';
import { launchChromeDriver, resolveChrome } from '../../../tool/reader_pitch_headless/cdp_client.mjs';
import { readPayload, vnShellConfig, vnShellPage } from './vn_shell_harness_support.mjs';

const scripts = readPayload();
if (!resolveChrome()) {
  console.log('Chrome unavailable');
  process.exit(77);
}
const W = 1200;
const H = 800;
const sentence = '彼の従兄が大きな弦楽器を抱えてステージ上に陣取り、監督生が持ち前の美しい声を上げた。';
// 段 0 / 1 短（任何预留下都是一屏），段 2 很长（一屏装不下、随可用盒变化拆成不同的片），段 3 短。
const body = '<p>一段目の短い文章です。</p><p>二段目の短い文章です。</p>' +
  '<p>' + sentence.repeat(60) + '</p><p>最後の短い段落です。</p>';
// 每秒 2 字：测试期间逐字显现不会自己跑完。
const config = vnShellConfig({ vnRevealSpeed: 2, dartPageWidth: W, dartPageHeight: H });
const page = vnShellPage(scripts, body, 'window.__fushiShells.vn(' + JSON.stringify(config) + ')');

const driver = await launchChromeDriver();
try {
  await driver.snap('<!doctype html><html></html>', null, W, H);
  const r = await driver.evalOnPage(page, `(async () => {
    for (let i = 0; i < 100 && !(window.fushiReader && window.fushiReader.contentStream); i++) {
      await new Promise((r) => setTimeout(r, 50));
    }
    const reader = window.fushiReader;
    let renders = 0;
    let fits = 0;
    const origRender = reader.renderScreen;
    const origFit = reader.fitScreensToViewport;
    reader.renderScreen = function() { renders++; return origRender.apply(this, arguments); };
    reader.fitScreensToViewport = function() { fits++; return origFit.apply(this, arguments); };
    const inset = () => document.documentElement.style.getPropertyValue('--chrome-bottom-inset');
    const snapshot = (dom) => ({
      renders: renders,
      fits: fits,
      sameDom: reader.screen.firstElementChild === dom,
      revealing: reader.revealComplete === false,
      index: reader.currentScreenIndex,
      start: reader.getFirstVisibleCharOffset(),
      end: reader.getLastVisibleCharOffset(),
      screens: reader.screens.length,
      inset: inset(),
    });
    const out = {};

    // 第 2 段（短）正在逐字显现。
    origRender.call(reader, 1, false);
    let dom = reader.screen.firstElementChild;
    out.initial = snapshot(dom);

    // ① 下发值与初始化写入的相同（悬浮底栏：恒 0）。
    reader.setChromeInsets(0, 0);
    out.unchanged = snapshot(dom);

    // ② 值变了（挤压态收起 / 弹出工具栏），短段落仍是同一屏。
    reader.setChromeInsets(0, 120);
    out.changedSameSlice = snapshot(dom);

    // ③ 当前屏在长段落之后：长段落在更矮的盒里拆出更多屏，当前屏下标后移、内容不变。
    renders = 0; fits = 0;
    origRender.call(reader, reader.screens.length - 1, false);
    dom = reader.screen.firstElementChild;
    out.lastBefore = snapshot(dom);
    reader.setChromeInsets(0, 400);
    out.lastAfter = snapshot(dom);

    // ④ 当前屏是长段落的第一片：盒变高后这一片装得下更多字，内容变了 → 重渲，首字不变。
    renders = 0; fits = 0;
    origRender.call(reader, 2, false);
    dom = reader.screen.firstElementChild;
    out.longBefore = snapshot(dom);
    reader.setChromeInsets(0, 0);
    out.longAfter = snapshot(dom);
    const box = reader.screen.getBoundingClientRect();
    out.longAfterOverflow = reader.screen.scrollWidth > Math.ceil(box.width) + 1 ||
      reader.screen.scrollHeight > Math.ceil(box.height) + 1;
    return out;
  })()`);
  const dump = JSON.stringify(r);
  assert.equal(r.initial.revealing, true, 'fixture: the screen is mid-reveal ' + dump);
  assert.equal(r.initial.index, 1, dump);

  assert.equal(r.unchanged.fits, 0, 'unchanged insets must not re-measure the chapter ' + dump);
  assert.equal(r.unchanged.renders, 0, 'unchanged insets must not re-render ' + dump);
  assert.equal(r.unchanged.sameDom && r.unchanged.revealing, true, 'the reveal keeps running ' + dump);

  assert.equal(r.changedSameSlice.inset, '120px', 'a changed inset is applied ' + dump);
  assert.equal(r.changedSameSlice.fits, 1, 'a changed box re-cuts the screen table once ' + dump);
  assert.equal(r.changedSameSlice.renders, 0, 'a screen whose content is unchanged is not re-rendered ' + dump);
  assert.equal(r.changedSameSlice.sameDom && r.changedSameSlice.revealing, true, 'the reveal keeps running ' + dump);
  assert.equal(r.changedSameSlice.index, 1, dump);

  assert.ok(r.lastAfter.screens > r.lastBefore.screens, 'fixture: the long paragraph splits into more screens ' + dump);
  assert.equal(r.lastAfter.renders, 0, 'a kept screen is not re-rendered when earlier screens split ' + dump);
  assert.equal(r.lastAfter.sameDom && r.lastAfter.revealing, true, dump);
  assert.equal(r.lastAfter.index, r.lastAfter.screens - 1, 'the kept screen adopts its new index ' + dump);
  assert.equal(r.lastAfter.start, r.lastBefore.start, dump);

  assert.ok(r.longAfter.end > r.longBefore.end, 'fixture: the taller box fits more of the long paragraph ' + dump);
  assert.equal(r.longAfter.renders, 1, 'a screen whose content changed is re-rendered ' + dump);
  assert.equal(r.longAfter.sameDom, false, dump);
  assert.equal(r.longAfter.start, r.longBefore.start, 'and still starts at the same character ' + dump);
  assert.equal(r.longAfterOverflow, false, 'the re-rendered screen fits the new box ' + dump);
  console.log('PASS VN chrome insets keep screen');
} finally {
  driver.close();
}
