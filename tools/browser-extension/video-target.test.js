// BUG-3143 / BUG-3144：视频页浮层的「跟谁定位」与「坐标系」不依赖站点 DOM。
//   ① 正片 = 全屏元素（本身是 <video>）或其内部 / 视口内可见面积最大的 <video>（在播优先），
//      不是文档里第一个 <video>——别的站第一个常是预告片、广告位、进度条缩略图预览。
//   ② position:fixed 浮层的坐标按父级包含块折算：站点给全屏容器 / body 加 transform 时，
//      视口坐标直接写进去会整体偏移、甚至被推出屏幕。
const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const VT = require('./video-target.js');

function rect(left, top, width, height) { return { left, top, width, height, right: left + width, bottom: top + height }; }

test('pickMainVideo：可见面积最大者胜，在播加权，完全在视口外 / 零尺寸不算', () => {
  const view = { width: 1280, height: 720 };
  const preview = { el: 'preview', rect: rect(0, 0, 320, 180), playing: true };
  const main = { el: 'main', rect: rect(100, 200, 960, 540), playing: false };
  const hidden = { el: 'hidden', rect: rect(0, 0, 0, 0), playing: true };
  const offscreen = { el: 'off', rect: rect(0, 2000, 1920, 1080), playing: true };
  assert.strictEqual(VT.pickMainVideo([preview, hidden, offscreen, main], view), 'main');
  // 同屏两个差不多大的视频：跟着正在播的那个走。
  const a = { el: 'a', rect: rect(0, 0, 600, 340), playing: false };
  const b = { el: 'b', rect: rect(640, 0, 560, 320), playing: true };
  assert.strictEqual(VT.pickMainVideo([a, b], view), 'b');
  assert.strictEqual(VT.pickMainVideo([hidden, offscreen], view), null);
  assert.strictEqual(VT.pickMainVideo([], view), null);
});

function fakeVideo(name, r, extra) {
  return Object.assign({ name, tagName: 'VIDEO', paused: true, ended: false, readyState: 4, getBoundingClientRect: () => r }, extra);
}

function runMainVideo(videos, fullscreenElement, viewport) {
  const ctx = {
    window: { innerWidth: (viewport || {}).width || 1280, innerHeight: (viewport || {}).height || 720 },
    document: {
      fullscreenElement: fullscreenElement || null,
      querySelectorAll: (s) => (s === 'video' ? videos : []),
      querySelector: (s) => (s === 'video' ? videos[0] || null : null),
      documentElement: {},
    },
  };
  ctx.self = ctx.window;
  vm.createContext(ctx);
  vm.runInContext(fs.readFileSync(path.join(__dirname, 'video-target.js'), 'utf8'), ctx);
  return ctx.window.fushiMainVideo();
}

test('mainVideo：非全屏挑视口内最大的，不是第一个（anichan 类站点的预告片 / 缩略图在前）', () => {
  const thumb = fakeVideo('thumb', rect(10, 650, 160, 90));
  const main = fakeVideo('main', rect(0, 60, 1280, 560));
  assert.strictEqual(runMainVideo([thumb, main]).name, 'main');
});

test('mainVideo：全屏元素就是 <video> 时直接用它；全屏容器只在其内部挑', () => {
  const outside = fakeVideo('outside', rect(0, 0, 1920, 1080), { paused: false });
  const inside = fakeVideo('inside', rect(0, 0, 1280, 720));
  assert.strictEqual(runMainVideo([outside, inside], inside).name, 'inside');
  const container = { tagName: 'DIV', contains: (v) => v === inside };
  assert.strictEqual(runMainVideo([outside, inside], container).name, 'inside');
});

test('mainVideo：都没有可见面积时退回第一个（旧行为，不变成 null 把功能关掉）', () => {
  const a = fakeVideo('a', rect(0, 0, 0, 0));
  const b = fakeVideo('b', rect(0, 3000, 100, 100));
  assert.strictEqual(runMainVideo([a, b]).name, 'a');
});

test('fixedOrigin：探针量出包含块原点与缩放；<html> 恒等；探针插在最前不抢浮层的「最后」', () => {
  assert.deepStrictEqual(VT.originFromProbeRect(rect(0, 0, 100, 100)), { x: 0, y: 0, sx: 1, sy: 1 });
  assert.deepStrictEqual(VT.originFromProbeRect(rect(40, -30, 50, 200)), { x: 40, y: -30, sx: 0.5, sy: 2 });
  assert.deepStrictEqual(VT.toFixed({ x: 40, y: -30, sx: 0.5, sy: 2 }, 140, 170), { left: 200, top: 100 });

  const html = { tagName: 'HTML' };
  const children = [{ name: 'overlay' }];
  const parent = {
    tagName: 'DIV',
    get firstChild() { return children[0] || null; },
    insertBefore(node, before) { const i = children.indexOf(before); children.splice(i < 0 ? children.length : i, 0, node); node.parentNode = parent; },
  };
  const ctx = {
    window: {},
    document: {
      documentElement: html,
      createElement: () => ({
        style: {}, setAttribute() {},
        getBoundingClientRect: () => rect(-120, 60, 100, 100), // 父级被 transform: translate(-120px, 60px)
      }),
    },
  };
  ctx.self = ctx.window;
  vm.createContext(ctx);
  vm.runInContext(fs.readFileSync(path.join(__dirname, 'video-target.js'), 'utf8'), ctx);
  assert.deepStrictEqual(JSON.parse(JSON.stringify(ctx.window.fushiFixedOrigin(html))), { x: 0, y: 0, sx: 1, sy: 1 });
  assert.deepStrictEqual(JSON.parse(JSON.stringify(ctx.window.fushiFixedOrigin(parent))), { x: -120, y: 60, sx: 1, sy: 1 });
  assert.strictEqual(children.length, 2);
  assert.strictEqual(children[1].name, 'overlay', '浮层仍是最后一个子节点');
  ctx.window.fushiFixedOrigin(parent);
  assert.strictEqual(children.length, 2, '探针复用，不重复插');
});

test('manifest：video-target.js 排在两个消费者（subtitle-panel / player-controls）之前', () => {
  const manifest = JSON.parse(fs.readFileSync(path.join(__dirname, 'manifest.json'), 'utf8'));
  const js = manifest.content_scripts[0].js;
  const at = js.indexOf('video-target.js');
  assert.ok(at >= 0);
  assert.ok(at < js.indexOf('subtitle-panel.js'));
  assert.ok(at < js.indexOf('player-controls.js'));
});
