// BUG-4907：VN 独立插图归类不随源树是否挂在文档上变化。
// 由 vn_refit_late_image_test.dart 执行，payload（生产 VN shell / 选区脚本 / 学习单位 / 生产 VN CSS）
// 经 stdin 送入。
//
// VN 在 initialize 里把整章正文搬进一个不挂在文档上的 div（detachChapterSource），之后所有归类
// （切屏的 containsStandaloneMedia、内容流的 mediaUnits、迟到图片复核）都对这棵脱离文档的树做。
// Blink / WebKit 对脱离文档的元素 getComputedStyle 一律给空值，所以旧判据最后一条
// `isBlockDisplay(computedDisplay(node))` 在生产里恒为 false；同一张图一旦挂在文档上，书本样式或
// 阅读器样式（`p > img:only-child { display:block }`）让它变成 block，归类就翻成「独立插图」。
// 断言：同一批节点挂着与摘下时归类相同，且与生产（脱离文档）一致；独立插图的正向判据
// （无文字上下文、block-img 类）两种状态下都成立。
import assert from 'node:assert/strict';
import { launchChromeDriver, resolveChrome } from '../../../tool/reader_pitch_headless/cdp_client.mjs';
import { readPayload, vnShellConfig, vnShellPage } from './reader_harness_support.js';

const scripts = readPayload();
if (!resolveChrome()) {
  console.log('Chrome unavailable');
  process.exit(77);
}
const W = 800;
const H = 600;
const config = vnShellConfig({ dartPageWidth: W, dartPageHeight: H });
const page = vnShellPage(scripts, '<p>本文です。</p>', 'window.__fushiShells.vn(' + JSON.stringify(config) + ')');

const driver = await launchChromeDriver();
try {
  const r = await driver.evalOnPage(page, `(async () => {
    for (let i = 0; i < 100 && !(window.fushiReader && window.fushiReader.contentStream); i++) {
      await new Promise((r) => setTimeout(r, 50));
    }
    const api = window.fushiReaderVnContentStream;
    const style = document.createElement('style');
    style.textContent = 'p > img:only-child { display: block; } .book-illust { display: block; }';
    document.head.appendChild(style);
    const cases = {
      inlineStyleBlock: '<p>前の文。<img style="display:block" width="20" height="20">後の文。</p>',
      readerOnlyChild: '<p>前の文。<img width="20" height="20">後の文。</p>',
      bookClassBlock: '<p>前の文。<img class="book-illust" width="20" height="20">後の文。</p>',
      imageOnly: '<p><img width="20" height="20"></p>',
      blockImgClass: '<p>前の文。<img class="block-img" width="20" height="20">後の文。</p>',
    };
    const out = {};
    for (const name of Object.keys(cases)) {
      const holder = document.createElement('div');
      holder.innerHTML = cases[name];
      const p = holder.firstElementChild;
      const img = holder.querySelector('img');
      document.documentElement.appendChild(holder);
      const attachedDisplay = getComputedStyle(img).display;
      const attached = api.isStandaloneImage(img, p);
      holder.remove();
      const detached = api.isStandaloneImage(img, p);
      out[name] = { attachedDisplay, attached, detached };
    }
    return out;
  })()`);
  // 前提：挂着时这几张小图确实是 block（否则本跑手测不出旧判据的翻转）。
  for (const name of ['inlineStyleBlock', 'readerOnlyChild', 'bookClassBlock']) {
    assert.equal(r[name].attachedDisplay, 'block', name + ': fixture must render the image as block while attached');
  }
  for (const name of Object.keys(r)) {
    assert.equal(r[name].attached, r[name].detached,
      name + ': classification must not depend on whether the source is attached ' + JSON.stringify(r[name]));
  }
  // 生产归类（脱离文档）：文字中间的小图仍是行内，不因样式里的 display:block 变成独立插图。
  for (const name of ['inlineStyleBlock', 'readerOnlyChild', 'bookClassBlock']) {
    assert.equal(r[name].detached, false, name + ': a small image inside text stays inline');
  }
  for (const name of ['imageOnly', 'blockImgClass']) {
    assert.equal(r[name].attached, true, name + ': standalone signal holds while attached');
    assert.equal(r[name].detached, true, name + ': standalone signal holds while detached');
  }
  console.log('PASS VN standalone image classification');
} finally {
  driver.close();
}
