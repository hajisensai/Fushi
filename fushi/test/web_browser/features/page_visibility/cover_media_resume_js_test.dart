import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/web_browser/features/page_visibility/web_browser_page_visibility_feature.dart';
import 'package:fushi/src/web_browser/features/play_in_fushi/play_in_fushi_feature.dart';

/// 浏览页被播放页盖住 / 露出时的页面脚本（BUG-4084 追加，用户 2026-11-05 拍板）：
/// 播放页退出后，按住前**正在播**的媒体续播；原本没在播的、盖住期间才想开播的都不动。
///
/// node 真执行 [kWebBrowserCoverHoldMediaScript] / [kWebBrowserCoverReleaseMediaScript]
/// （以及交接用的那对 [kWebBrowserHoldMediaScript] / [kWebBrowserReleaseMediaScript]），
/// 跑在一个最小的假 DOM 上（`querySelectorAll` + 捕获阶段 `play` 监听 + 媒体元素的
/// `paused` / `play()` / `pause()`）。无 node 时 skip。真 WebView 上的续播（自动播放策略）
/// 不在本层测。
void main() {
  test('盖住记下在播的、露出只续播它们；交接按住不续播（node 执行页面脚本）', () async {
    final String? nodeExe = _resolveNode();
    if (nodeExe == null) {
      markTestSkipped('node not found on PATH; skipping JS behavior execution');
      return;
    }
    final Directory dir = Directory.systemTemp.createTempSync(
      'fushi_cover_resume_js_',
    );
    addTearDown(() => dir.deleteSync(recursive: true));
    final File harness = File('${dir.path}${Platform.pathSeparator}h.js')
      ..writeAsStringSync(_harness());

    final ProcessResult result = await Process.run(nodeExe, <String>[
      harness.path,
    ]);
    expect(
      result.exitCode,
      0,
      reason: 'stdout:\n${result.stdout}\nstderr:\n${result.stderr}',
    );
    expect(result.stdout.toString(), contains('all assertions passed'));
  });
}

String _harness() =>
    '''
const COVER_HOLD = ${jsonEncode(kWebBrowserCoverHoldMediaScript)};
const COVER_RELEASE = ${jsonEncode(kWebBrowserCoverReleaseMediaScript)};
const HOLD = ${jsonEncode(kWebBrowserHoldMediaScript)};
const RELEASE = ${jsonEncode(kWebBrowserReleaseMediaScript)};
const assert = require('assert');

let listeners;
let els;
globalThis.window = globalThis;
globalThis.document = {
  querySelectorAll: () => els.filter((e) => e.isConnected),
  addEventListener: (t, h) => { (listeners[t] = listeners[t] || []).push(h); },
  removeEventListener: (t, h) => {
    listeners[t] = (listeners[t] || []).filter((x) => x !== h);
  },
};
function reset() {
  listeners = {};
  els = [];
  window.__fushiMediaHold = undefined;
  window.__fushiCoverResume = undefined;
}
function media(name, playing) {
  const e = {
    name, paused: !playing, ended: false, isConnected: true, plays: 0,
    reject: false,
    pause() { this.paused = true; },
    play() {
      this.plays++;
      this.paused = false;
      for (const h of (listeners.play || []).slice()) h({ target: this });
      // 自动播放策略拒绝时 play() 的 promise 被拒：脚本必须吞掉，不能留未处理拒绝。
      return this.reject ? Promise.reject(new Error('blocked')) : Promise.resolve();
    },
  };
  els.push(e);
  return e;
}
const run = (src) => (0, eval)(src);

// 1. 在播的续播；原本暂停的、盖住期间才想开播的不动；露出后按住监听已摘。
reset();
{
  const a = media('a', true);
  const b = media('b', false);
  run(COVER_HOLD);
  assert.strictEqual(a.paused, true, 'cover hold pauses playing media');
  b.play();
  assert.strictEqual(b.paused, true, 'autoplay during cover is held');
  const c = media('c', false);
  c.play();
  assert.strictEqual(c.paused, true, 'media created during cover is held');
  // 重复按住（落地失败重做）不重复记录。
  run(COVER_HOLD);
  a.reject = true;
  run(COVER_RELEASE);
  a.reject = false;
  assert.strictEqual(a.paused, false, 'media playing before cover resumes');
  assert.strictEqual(a.plays, 1, 'resumed exactly once');
  assert.strictEqual(b.paused, true, 'media paused before cover stays paused');
  assert.strictEqual(c.paused, true, 'media that only tried to play during cover stays paused');
  assert.strictEqual(window.__fushiCoverResume, null, 'resume record consumed');
  b.play();
  assert.strictEqual(b.paused, false, 'hold listener removed after release');
  // 再露出一次（落地失败重做）不再续播。
  a.pause();
  run(COVER_RELEASE);
  assert.strictEqual(a.paused, true, 'release without a record resumes nothing');
}

// 2. 站点自己已经续上 / 元素已移出文档：不重复播、不播孤儿元素。
reset();
{
  const a = media('a', true);
  const d = media('d', true);
  run(COVER_HOLD);
  a.paused = false;
  d.isConnected = false;
  run(COVER_RELEASE);
  assert.strictEqual(a.plays, 0, 'already-resumed media is not played again');
  assert.strictEqual(d.plays, 0, 'detached media is not played');
}

// 3. 交接（用 Fushi 播放）：那对脚本只按住 / 解除，不续播。
reset();
{
  const a = media('a', true);
  run(HOLD);
  run(RELEASE);
  assert.strictEqual(a.paused, true, 'handoff release does not resume');
}

// 4. 交接先按住、播放页再盖住：盖住时已没有在播的，回来不续播网页。
reset();
{
  const a = media('a', true);
  run(HOLD);
  run(COVER_HOLD);
  run(RELEASE);
  run(COVER_RELEASE);
  assert.strictEqual(a.paused, true, 'handed-off media is not resumed');
  assert.strictEqual(a.plays, 0);
}

// 5. 盖住期间换了文档：只重新按住（不记），露出不续播新文档里自动播的。
reset();
{
  const t = media('trailer', true);
  run(HOLD);
  run(COVER_RELEASE);
  assert.strictEqual(t.paused, true, 'reloaded-while-hidden autoplay is not resumed');
}

console.log('all assertions passed');
''';

String? _resolveNode() {
  final String exe = Platform.isWindows ? 'node.exe' : 'node';
  final String pathEnv = Platform.environment['PATH'] ?? '';
  final String separator = Platform.isWindows ? ';' : ':';
  for (final String dir in pathEnv.split(separator)) {
    if (dir.isEmpty) continue;
    final File candidate = File('$dir${Platform.pathSeparator}$exe');
    if (candidate.existsSync()) return candidate.path;
  }
  return null;
}
