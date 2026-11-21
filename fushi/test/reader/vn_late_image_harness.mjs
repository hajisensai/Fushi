// VN 首屏不等图片：真 Chrome 里的行为跑手。
// 由 vn_refit_late_image_test.dart 执行，payload（生产 VN shell + 选区脚本 + 生产 VN CSS 的
// JSON）经 stdin 送入。
//
// 修前：initialize 先等源章节每一张 <img> 的 load / error 才切屏，没有任何时限。一张迟迟
// 不结束的图（这里的 never.png：服务器接了请求永不回应）让首屏一直不出——body 已被搬空，
// 宿主 8 秒兜底揭开遮罩后看到的是空白。
//
// 修后：按已知信息先切屏（没加载完的图认 width / height 属性），图 load 后复核：
// - 归类变了（行内 → 独立图片屏）→ 整章重建屏表；当前屏内容没变就原地保留，变了按首字符
//   偏移落回并重渲；
// - 屏上的克隆自己 load 后补升 block-img；
// - 归类没变的行内图只按新尺寸重切（不重建屏表）；
// - 归类没变、本来就是独立媒体的图（纯图片段、属性写明大尺寸）不触发任何重切：它所在的
//   屏不可拆、不参与量屏，整章重量一遍改变不了任何一屏。
// 图片由本文件起的回环服务器按需放行，页面里用 fetch('/release?name') 触发。
import http from 'node:http';
import zlib from 'node:zlib';
import assert from 'node:assert/strict';
import { launchChromeDriver, resolveChrome } from '../../../tool/reader_pitch_headless/cdp_client.mjs';
import { readPayload, vnShellConfig, vnShellPage } from './reader_harness_support.js';

const scripts = readPayload();
if (!resolveChrome()) {
  console.log('Chrome unavailable');
  process.exit(77);
}
const W = 1200;
const H = 800;

// 一张纯灰的 size×size PNG（手写编码，不依赖 npm 包）。
function png(size) {
  const crcTable = new Int32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    crcTable[n] = c;
  }
  const crc = (buf) => {
    let c = -1;
    for (const byte of buf) c = crcTable[(c ^ byte) & 0xff] ^ (c >>> 8);
    return (c ^ -1) >>> 0;
  };
  const chunk = (type, data) => {
    const head = Buffer.alloc(4);
    head.writeUInt32BE(data.length);
    const body = Buffer.concat([Buffer.from(type, 'ascii'), data]);
    const tail = Buffer.alloc(4);
    tail.writeUInt32BE(crc(body));
    return Buffer.concat([head, body, tail]);
  };
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(size, 0);
  ihdr.writeUInt32BE(size, 4);
  ihdr[8] = 8; // bit depth
  ihdr[9] = 0; // greyscale
  const raw = Buffer.alloc((size + 1) * size, 0x80);
  for (let y = 0; y < size; y++) raw[y * (size + 1)] = 0;
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk('IHDR', ihdr),
    chunk('IDAT', zlib.deflateSync(raw)),
    chunk('IEND', Buffer.alloc(0)),
  ]);
}
const bigPng = png(300);
const smallPng = png(16);

// /img/<name>.png：放行前挂住，放行后立即回 300×300 的图（small 开头的回 16×16）；
// never 永不放行。
const released = new Set();
const held = new Map();
const serve = (res, name) => {
  res.setHeader('content-type', 'image/png');
  res.setHeader('cache-control', 'max-age=3600');
  res.end(name.startsWith('small') ? smallPng : bigPng);
};
const server = http.createServer((req, res) => {
  const url = new URL(req.url, 'http://127.0.0.1');
  if (url.pathname === '/release') {
    const name = url.search.slice(1);
    released.add(name);
    (held.get(name) || []).forEach((pending) => serve(pending, name));
    held.delete(name);
    res.setHeader('access-control-allow-origin', '*');
    res.end('ok');
    return;
  }
  const m = /^\/img\/([a-z0-9]+)\.png$/.exec(url.pathname);
  if (!m) {
    res.statusCode = 404;
    res.end();
    return;
  }
  if (released.has(m[1])) {
    serve(res, m[1]);
    return;
  }
  if (!held.has(m[1])) held.set(m[1], []);
  held.get(m[1]).push(res);
});
await new Promise((resolve, reject) => {
  server.once('error', reject);
  server.listen(0, '127.0.0.1', resolve);
});
const origin = 'http://127.0.0.1:' + server.address().port;
const img = (name, attrs) => '<img id="' + name + '" src="' + origin + '/img/' + name + '.png"' + (attrs || '') + '>';

// 块模式一段一屏：
//   0 文字 / 1 文字 + late1（行内，加载后 300px → 独立）/ 2 文字 / 3 文字 + late2 /
//   4 纯图片段 late3（没有文字，始终独立屏）/ 5 文字 + declared（属性写明 400×300）/
//   6 纯图片段 never（永不加载）/ 7 文字 / 8 文字 + small（16px，加载后仍是行内）
const body =
  '<p>一段目の文章です。</p>' +
  '<p>二段目の途中に' + img('late1') + '挿絵が入ります。</p>' +
  '<p>三段目の文章です。</p>' +
  '<p>四段目の途中に' + img('late2') + '挿絵が入ります。</p>' +
  '<p>' + img('late3') + '</p>' +
  '<p>六段目の途中に' + img('declared', ' width="400" height="300"') + '挿絵が入ります。</p>' +
  '<p>' + img('never') + '</p>' +
  '<p>八段目の文章です。</p>' +
  '<p>九段目の途中に' + img('small') + '小さな絵が入ります。</p>';
const config = vnShellConfig({ dartPageWidth: W, dartPageHeight: H });
// 页面先以空 body 加载完（挂住的图片会一直拖着 window load 事件），再由下面的脚本填正文、
// 装 VN shell——与真实阅读器「正文在文档里、图片还在加载时 shell 启动」同一时序。
const page = vnShellPage(scripts, '');

const driver = await launchChromeDriver();
try {
  await driver.snap('<!doctype html><html></html>', null, W, H);
  const r = await driver.evalOnPage(page, `(async () => {
    const until = async (cond, ms) => {
      const end = Date.now() + ms;
      while (Date.now() < end) {
        if (cond()) return true;
        await new Promise((r) => setTimeout(r, 20));
      }
      return !!cond();
    };
    const release = (name) => fetch(${JSON.stringify(origin)} + '/release?' + name, { mode: 'cors' });
    document.body.innerHTML = ${JSON.stringify(body)};
    window.__fushiShells.vn(${JSON.stringify(config)});
    const out = {};
    // ① 还有图片没加载完（never 永远不会），首屏照样切出来并通知宿主。
    out.ready = await until(() => window.fushiReader && window.fushiReader.screens &&
      window.fushiReader.screens.length > 0 &&
      window.__handlerCalls.indexOf('onRestoreComplete') >= 0, 5000);
    if (!out.ready) return out;
    const reader = window.fushiReader;
    const source = (id) => reader.sourceRoot.querySelector('#' + id);
    out.pendingAtReady = ['late1', 'late2', 'late3', 'never', 'declared', 'small'].map((id) => source(id).complete);
    const table = () => reader.screens.map((s) => [s.startCharCount, s.endCharCount, !!s.mediaStop, !!s.splittable]);
    out.before = table();
    let renders = 0;
    const origRender = reader.renderScreen;
    reader.renderScreen = function() { renders++; return origRender.apply(this, arguments); };
    // 整章量屏次数：迟到的图引起的每一次重切（重建屏表或只重量）都会走到这里。
    let fits = 0;
    const origFit = reader.fitScreensToViewport;
    reader.fitScreensToViewport = function() { fits++; return origFit.apply(this, arguments); };
    // 源图 load / error 之后，等合并用的零延时任务（如果排了的话）跑完。
    const settled = async (id) => {
      const done = await until(() => source(id).complete, 5000);
      for (let i = 0; i < 10; i++) await new Promise((r) => setTimeout(r, 0));
      return done;
    };

    // ② 别的屏上的图加载完、归类变了：屏表重建，当前屏（第 3 段）内容没变 → 原地保留。
    origRender.call(reader, 2, true);
    const kept = reader.screen.firstElementChild;
    await release('late1');
    out.late1Reclassified = await until(() => reader.screens[1] && reader.screens[1].mediaStop === true, 5000);
    out.afterLate1 = {
      table: table(),
      renders: renders,
      sameDom: reader.screen.firstElementChild === kept,
      index: reader.currentScreenIndex,
      fits: fits,
    };

    // ③ 当前屏自己的图加载完、归类变了：按首字符偏移落回并重渲，屏上的图升成 block-img。
    origRender.call(reader, 3, true);
    const start = reader.getFirstVisibleCharOffset();
    renders = 0;
    await release('late2');
    out.late2Rerendered = await until(() => renders > 0, 5000);
    await until(() => !!reader.screen.querySelector('.block-img-wrapper > img.block-img'), 5000);
    out.afterLate2 = {
      renders: renders,
      index: reader.currentScreenIndex,
      sameStart: reader.getFirstVisibleCharOffset() === start,
      mediaStop: reader.screens[reader.currentScreenIndex].mediaStop === true,
      promoted: !!reader.screen.querySelector('.block-img-wrapper > img.block-img'),
    };

    // ④ 纯图片屏：图还没到时已经是独立屏；图到了屏表不变、屏不重渲，屏上的克隆自己补升。
    origRender.call(reader, 4, true);
    const imageScreen = reader.screen.firstElementChild;
    out.imageScreenBefore = {
      mediaStop: reader.screens[4].mediaStop === true,
      promoted: !!reader.screen.querySelector('img.block-img'),
    };
    renders = 0;
    fits = 0;
    await release('late3');
    out.imageScreenPromoted = await until(
      () => !!reader.screen.querySelector('.block-img-wrapper > img.block-img'), 5000);
    out.late3Settled = await settled('late3');
    out.imageScreenAfter = {
      renders: renders,
      sameDom: reader.screen.firstElementChild === imageScreen,
      index: reader.currentScreenIndex,
      fits: fits,
    };

    // ⑤ 属性已写明大尺寸的图：加载前后都是独立媒体，同样不重切。
    await release('declared');
    out.declaredSettled = await settled('declared');
    out.afterDeclared = { fits: fits, renders: renders };

    // ⑥ 加载后仍是行内的小图：归类没变，但它的尺寸会改变所在文字屏装得下多少 → 只重量
    //    一次，不重建屏表、当前屏不重渲。
    const baseBefore = reader.baseScreens;
    await release('small');
    out.smallSettled = await settled('small');
    out.afterSmall = {
      fits: fits,
      renders: renders,
      sameBase: reader.baseScreens === baseBefore,
      index: reader.currentScreenIndex,
    };
    out.after = table();
    return out;
  })()`);
  const dump = JSON.stringify(r);
  assert.equal(r.ready, true, 'the first screen must not wait for images that never finish ' + dump);
  assert.deepEqual(r.pendingAtReady, [false, false, false, false, false, false], 'fixture: every image is still loading at ready ' + dump);
  assert.equal(r.before.length, 9, 'fixture cuts nine screens ' + dump);
  // [start, end, mediaStop, splittable]
  assert.deepEqual([r.before[1][2], r.before[1][3]], [false, true], 'a loading image without declared size is inline for now ' + dump);
  assert.deepEqual([r.before[4][2], r.before[4][3]], [true, false], 'an image-only paragraph is a media screen before it loads ' + dump);
  assert.deepEqual([r.before[5][2], r.before[5][3]], [true, false], 'a loading image is classified by its declared size ' + dump);
  assert.deepEqual([r.before[6][2], r.before[6][3]], [true, false], dump);

  assert.equal(r.late1Reclassified, true, 'a late image that turns out large re-cuts the chapter ' + dump);
  assert.equal(r.afterLate1.table.length, 9, dump);
  assert.ok(r.afterLate1.fits >= 1, 'control: a re-cut goes through fitScreensToViewport ' + dump);
  assert.equal(r.afterLate1.renders, 0, 'an unchanged current screen is not re-rendered ' + dump);
  assert.equal(r.afterLate1.sameDom, true, 'the current screen DOM is kept ' + dump);
  assert.equal(r.afterLate1.index, 2, dump);

  assert.equal(r.late2Rerendered, true, 'a re-classified current screen is re-rendered ' + dump);
  assert.equal(r.afterLate2.index, 3, 'and lands back on the same paragraph ' + dump);
  assert.equal(r.afterLate2.sameStart, true, dump);
  assert.equal(r.afterLate2.mediaStop, true, dump);
  assert.equal(r.afterLate2.promoted, true, 'the on-screen image is promoted to a block image ' + dump);

  assert.deepEqual(r.imageScreenBefore, { mediaStop: true, promoted: false }, dump);
  assert.equal(r.imageScreenPromoted, true, 'a clone that loads after render is promoted on its own load ' + dump);
  assert.equal(r.late3Settled, true, dump);
  assert.deepEqual(r.imageScreenAfter, { renders: 0, sameDom: true, index: 4, fits: 0 },
    'an image-only paragraph neither re-renders nor re-measures the chapter when its image arrives ' + dump);
  assert.equal(r.declaredSettled, true, dump);
  assert.deepEqual(r.afterDeclared, { fits: 0, renders: 0 },
    'an image that was already a media screen by its declared size does not re-measure the chapter ' + dump);
  assert.equal(r.smallSettled, true, dump);
  assert.deepEqual(r.afterSmall, { fits: 1, renders: 0, sameBase: true, index: 4 },
    'a late inline image re-measures once without rebuilding the screen table ' + dump);
  assert.deepEqual(r.after.map((s) => s[2]), [false, true, false, true, true, true, true, false, false], dump);
  console.log('PASS VN late image');
} finally {
  driver.close();
  server.closeAllConnections?.();
  server.close();
}
