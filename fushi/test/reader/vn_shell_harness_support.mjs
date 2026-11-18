// 真 Chrome 行为跑手共用的两样东西：从 stdin 读 Dart 测试送来的 payload，以及把生产 VN
// shell 装进一张页面。各跑手只留自己的正文、要改的 config 项和断言。
import fs from 'node:fs';

/// Dart 测试把 payload（生产脚本 / CSS 的 JSON）经 stdin 送进来，不经命令行传文件路径。
/// 要在探测 Chrome 之前读：跑手提前退出时写端不会撞上已关闭的管道。
export function readPayload() {
  return JSON.parse(fs.readFileSync(0, 'utf8'));
}

/// VN shell 的启动 config：块模式一段一屏、从章首开始、没有有声书、不预留工具栏。
/// [overrides] 覆盖其中几项（视口、逐字显现速度等）。
export function vnShellConfig(overrides) {
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
export function vnShellPage(scripts, body, boot) {
  const bridge = 'window.__fushiShells={};window.__handlerCalls=[];' +
    'window.flutter_inappwebview={callHandler:function(name){' +
    'window.__handlerCalls.push(name);return Promise.resolve(null);}};';
  return '<!doctype html><html><head><meta charset="utf-8">' +
    '<style>' + scripts.css + '</style>' +
    '<script>' + bridge + scripts.units + '</script>' + scripts.shell +
    '<script>' + scripts.selection + (boot ? ';' + boot : '') + '</script>' +
    '</head><body>' + body + '</body></html>';
}
