// BUG-4907 + 拍板台 design-nmv-fyi-tail ①：VN 独立插图归类不随源树是否挂在文档上变化，且
// 书本 CSS 排成块级的小图算独立插图、阅读器自己的 `p > img:only-child` 规则不算。
// 由 vn_refit_late_image_test.dart 执行，payload（生产 VN shell / 选区脚本 / 学习单位 / 生产 VN CSS）
// 经 stdin 送入。
//
// VN 在 initialize 里把整章正文搬进一个不挂在文档上的 div（detachChapterSource），之后所有归类
// （切屏的 containsStandaloneMedia、内容流的 mediaUnits、迟到图片复核）都对这棵脱离文档的树做。
// Blink / WebKit 对脱离文档的元素 getComputedStyle 一律给空值，所以「书本样式说它是块级」只能在
// 摘下之前量一次（markBookBlockImages，量时关掉阅读器自己的样式表），记成节点属性。
// 断言：
// ① 同一批节点挂着与摘下时归类相同；书本行内 style / 书本样式表的 display:block → 独立插图；
//    阅读器样式（id=fushi-reader-style）的 `:only-child` 规则 → 仍是行内；无文字上下文、block-img
//    类两种状态下都是独立插图。
// ② 生产启动路径（整页 + 书本样式在 head）：initialize 之后源树里书本块级小图带标记、独占一屏，
//    阅读器规则命中的小图没有标记、留在文字屏里。
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
// 生产里阅读器样式表带 id="fushi-reader-style"（reader_fushi_page.dart），跑手页同样标上。
const withReaderStyleId = (html) => html.replace('<style>', '<style id="fushi-reader-style">');
const page = withReaderStyleId(
  vnShellPage(scripts, '<p>本文です。</p>', 'window.__fushiShells.vn(' + JSON.stringify(config) + ')'));

const driver = await launchChromeDriver();
try {
  const r = await driver.evalOnPage(page, `(async () => {
    for (let i = 0; i < 100 && !(window.fushiReader && window.fushiReader.contentStream); i++) {
      await new Promise((r) => setTimeout(r, 50));
    }
    const api = window.fushiReaderVnContentStream;
    const book = document.createElement('style');
    book.textContent = '.book-illust { display: block; }';
    document.head.appendChild(book);
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
      document.body.appendChild(holder);
      const attachedDisplay = getComputedStyle(img).display;
      api.markBookBlockImages(document);
      const attached = api.isStandaloneImage(img, p);
      holder.remove();
      const detached = api.isStandaloneImage(img, p);
      out[name] = { attachedDisplay, attached, detached };
    }
    return out;
  })()`);
  // 前提：挂着时这几张小图确实是 block（阅读器规则也确实命中），否则本跑手测不出区分。
  for (const name of ['inlineStyleBlock', 'readerOnlyChild', 'bookClassBlock']) {
    assert.equal(r[name].attachedDisplay, 'block', name + ': fixture must render the image as block while attached');
  }
  for (const name of Object.keys(r)) {
    assert.equal(r[name].attached, r[name].detached,
      name + ': classification must not depend on whether the source is attached ' + JSON.stringify(r[name]));
  }
  assert.equal(r.readerOnlyChild.detached, false, "the reader's own :only-child rule does not make an image standalone");
  for (const name of ['inlineStyleBlock', 'bookClassBlock', 'imageOnly', 'blockImgClass']) {
    assert.equal(r[name].detached, true, name + ': standalone ' + JSON.stringify(r[name]));
  }

  // ② 生产启动路径：书本样式在 head，正文两段各夹一张小图。
  const body = '<p>一段目の文。<img id="bookBlock" class="book-illust" width="20" height="20">続きの文。</p>' +
    '<p>二段目の文。<img id="readerRule" width="20" height="20">続きの文。</p>';
  const fullPage = withReaderStyleId(
    vnShellPage(scripts, body, 'window.__fushiShells.vn(' + JSON.stringify(config) + ')'))
    .replace('</head>', '<style>.book-illust { display: block; }</style></head>');
  const e2e = await driver.evalOnPage(fullPage, `(async () => {
    for (let i = 0; i < 100 && !(window.fushiReader && window.fushiReader.screens && window.fushiReader.screens.length); i++) {
      await new Promise((r) => setTimeout(r, 50));
    }
    const reader = window.fushiReader;
    const source = reader.sourceRoot;
    const attr = 'data-fushi-vn-book-block';
    return {
      bookMarked: source.querySelector('#bookBlock').hasAttribute(attr),
      readerMarked: source.querySelector('#readerRule').hasAttribute(attr),
      bookStandalone: window.fushiReaderVnContentStream.isStandaloneImage(
        source.querySelector('#bookBlock'), source.querySelector('#bookBlock').parentNode),
      readerStandalone: window.fushiReaderVnContentStream.isStandaloneImage(
        source.querySelector('#readerRule'), source.querySelector('#readerRule').parentNode),
      readerStyleEnabled: !document.getElementById('fushi-reader-style').sheet.disabled,
    };
  })()`);
  assert.equal(e2e.bookMarked, true, 'book CSS block image is marked before detach ' + JSON.stringify(e2e));
  assert.equal(e2e.readerMarked, false, 'reader rule image is not marked ' + JSON.stringify(e2e));
  assert.equal(e2e.bookStandalone, true, JSON.stringify(e2e));
  assert.equal(e2e.readerStandalone, false, JSON.stringify(e2e));
  assert.equal(e2e.readerStyleEnabled, true, 'reader stylesheet is re-enabled after measuring');
  console.log('PASS VN standalone image classification');
} finally {
  driver.close();
}
