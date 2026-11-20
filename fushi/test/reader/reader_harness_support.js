// reader 测试 Node 跑手的公共段（Node 行为跑手与真 Chrome 跑手共用，CommonJS，ESM 跑手用
// `import { readPayload } from './reader_harness_support.js'` 取具名导出）：
// - 从 stdin 读 Dart 测试送来的 payload（生产脚本 / CSS 的 JSON），命令行不传文件路径；
// - 把生产 shell 里 `window.fushiReader = { ... }` 的对象字面量切出来，用 `node:vm` 的
//   compileFunction 编译成「全局全由跑手传入替身」的函数（不用 `new Function`）；
// - 按假 scroll 位置换算的假 DOM Range；
// - 真 Chrome 跑手装生产 VN shell 的启动 config 与页面。

const assert = require('node:assert');
const fs = require('node:fs');
const vm = require('node:vm');

/// Dart 测试把 payload 经 stdin 送进来（`test/helpers/node_runtime.dart` 的 runNodeHarness）。
/// 跑手要在探测 Chrome / 提前退出之前读：先退出时 Dart 那头的写端会撞上已关闭的管道。
function readPayload() {
  return JSON.parse(fs.readFileSync(0, 'utf8'));
}

function mustFind(source, needle, from, what) {
  const at = source.indexOf(needle, from);
  assert.ok(at >= 0, what + ' missing');
  return at;
}

/// shell 脚本里赋给 `window.fushiReader` 的 `{ ... }` 字面量（到第一个行首 `};` 为止）。
function shellObjectLiteral(shellSource) {
  const opening = 'window.fushiReader = {';
  const open = mustFind(shellSource, opening, 0, 'fushiReader object') + opening.length - 1;
  const close = mustFind(shellSource, '\n};', open, 'fushiReader object terminator');
  return shellSource.slice(open, close + 2);
}

/// 把生产脚本正文编译成以 [parameters] 为形参的函数：脚本碰到的每个全局都是跑手显式传入的
/// 替身。[filename] 是被编译脚本在调用栈里显示的文件名。
function compileScript(parameters, body, filename) {
  return vm.compileFunction(body, parameters, { filename });
}

/// 文档坐标 `geom.doc`（翻页轴上长 `geom.size`）的盒，在当前假 scroll `state.scroll` 下的
/// client rect。
function scrolledRect(state, geom) {
  const left = geom.doc - state.scroll;
  return { left, right: left + geom.size, top: 100, bottom: 120, width: geom.size, height: 20 };
}

/// 覆盖那个盒的假 DOM Range；每次读矩形都按当时的 scroll 重算。
function scrolledRange(state, geom) {
  const rect = () => scrolledRect(state, geom);
  return {
    getClientRects: () => [rect()],
    getBoundingClientRect: rect,
    cloneRange: () => scrolledRange(state, geom),
  };
}

/// VN shell 的启动 config：块模式一段一屏、从章首开始、没有有声书、不预留工具栏。
/// [overrides] 覆盖其中几项（视口、逐字显现速度等）。
function vnShellConfig(overrides) {
  return Object.assign({
    vnRevealSpeed: 0,
    vnScreenMode: 'block',
    vnSentencesPerScreen: 1,
    vnPreserveDialogue: false,
    vnMergeCrossScreenSentenceAudioCues: false,
    sentenceAudioCues: [],
    initialProgress: 0,
    initialFragment: null,
    initialCharOffset: -1,
    navigationGeneration: 1,
    chromeTopInset: 0,
    chromeBottomInset: 0,
    blurImages: false,
    revealedKeys: [],
  }, overrides);
}

/// 装好生产 VN CSS / shell / 选区脚本的页面。宿主桥是替身：每次 callHandler 的名字记进
/// `window.__handlerCalls`。[boot] 是接在选区脚本后面执行的启动语句（不给就只装不启动，
/// 由跑手自己在页面里调 `window.__fushiShells.vn(config)`），[body] 是正文 HTML。
function vnShellPage(scripts, body, boot) {
  const bridge = 'window.__fushiShells={};window.__handlerCalls=[];' +
    'window.flutter_inappwebview={callHandler:function(name){' +
    'window.__handlerCalls.push(name);return Promise.resolve(null);}};';
  return '<!doctype html><html><head><meta charset="utf-8">' +
    '<style>' + scripts.css + '</style>' +
    '<script>' + bridge + scripts.units + '</script>' + scripts.shell +
    '<script>' + scripts.selection + (boot ? ';' + boot : '') + '</script>' +
    '</head><body>' + body + '</body></html>';
}

module.exports = {
  readPayload,
  shellObjectLiteral,
  compileScript,
  scrolledRect,
  scrolledRange,
  vnShellConfig,
  vnShellPage,
};
