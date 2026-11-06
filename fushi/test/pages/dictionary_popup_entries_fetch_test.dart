import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/popup_settings_injection.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';

/// P1-B（2026-10-20，用户：查词卡手）：大结果的词条 JSON 不再在 UI isolate 上
/// `jsonEncode` 成 JS 字面量、经平台通道塞进脚本再整体编译——页面经宿主资源拦截器
/// `fetch` 取回 UTF-8 字节。这里钉住页面侧胶水脚本的三条契约：
///   ① 词条正文不进脚本；
///   ② 渲染令牌门：慢回来的旧令牌取回作废，绝不覆盖新结果；
///   ③ 取回失败经 `popupEntriesFetchFailed` 报给宿主（宿主据此改走字面量重推），
///      旧令牌的失败不报。
/// ②③ 用 node 真执行生成的脚本（无 node 时 skip）。
void main() {
  DictionarySearchResult resultWithMarker(String marker) =>
      DictionarySearchResult(searchTerm: 'x')..popupJson = '[{"w":"$marker"}]';

  String script({
    required int token,
    required String url,
    required String afterEntriesJs,
  }) => buildPopupFetchedEntriesJs(
    result: resultWithMarker('BODY_MARKER_$token'),
    url: url,
    renderToken: token,
    pending: false,
    idle: false,
    afterEntriesJs: afterEntriesJs,
  );

  test('词条正文不进脚本，只有取回 URL 与令牌门', () {
    final String js = script(
      token: 7,
      url: 'https://fushi.local/popup-entries/1/7.json',
      afterEntriesJs: 'window.renderPopup();',
    );
    expect(
      js,
      isNot(contains('BODY_MARKER_7')),
      reason: '词条 JSON 必须经拦截器取，不得再内联进脚本',
    );
    expect(js, contains('"https://fushi.local/popup-entries/1/7.json"'));
    expect(js, contains('window.__fushiRenderToken !== token'));
    expect(js, contains("callHandler('popupEntriesFetchFailed'"));
    // 渲染收尾（renderPopup 等）只在取回且令牌仍有效时执行。
    final int applyAt = js.indexOf('function apply(entries)');
    final int renderAt = js.indexOf('window.renderPopup();');
    final int fetchAt = js.indexOf('fetch(');
    expect(applyAt, greaterThanOrEqualTo(0));
    expect(renderAt, greaterThan(applyAt));
    expect(renderAt, lessThan(fetchAt));
  });

  test('字面量路径（小结果 / Linux / 回退）仍内联且与取回路径同一份元数据', () {
    final DictionarySearchResult r = resultWithMarker('INLINE_MARKER');
    final String literal = buildPopupEntriesJs(r, pending: true);
    expect(literal, contains('INLINE_MARKER'));
    expect(literal, contains('window.lookupPending = true;'));
    expect(popupEntriesJsonOf(r), r.popupJson);
    expect(kPopupEntriesFetchMinChars, greaterThan(0));
  });

  test('令牌门与失败上报（executes the generated glue via node）', () async {
    final String? nodeExe = _resolveNode();
    if (nodeExe == null) {
      markTestSkipped('node not found on PATH; skipping JS behavior execution');
      return;
    }
    const String url1 = 'https://fushi.local/popup-entries/1/1.json';
    const String url2 = 'https://fushi.local/popup-entries/1/2.json';
    const String url3 = 'https://fushi.local/popup-entries/1/3.json';
    const String url4 = 'https://fushi.local/popup-entries/1/4.json';
    const String record =
        'window.__rendered.push('
        'window.lookupEntries.length ? window.lookupEntries[0].w : null);';
    final String harness =
        '''
const assert = require('assert');
const calls = [];
global.window = {
  __rendered: [],
  flutter_inappwebview: { callHandler: (...args) => { calls.push(args); } },
};
const pending = {};
global.fetch = (url) => new Promise((res, rej) => { pending[url] = { res, rej }; });
const respond = (url, body) => pending[url].res({ ok: true, status: 200, text: () => Promise.resolve(body) });
const fail = (url) => pending[url].rej(new Error('blocked'));
const tick = () => new Promise((r) => setTimeout(r, 0));
(async () => {
  window.__fushiRenderToken = 1;
  eval(${jsonEncode(script(token: 1, url: url1, afterEntriesJs: record))});
  window.__fushiRenderToken = 2;
  eval(${jsonEncode(script(token: 2, url: url2, afterEntriesJs: record))});
  respond(${jsonEncode(url2)}, '[{"w":"new"}]');
  await tick();
  respond(${jsonEncode(url1)}, '[{"w":"old"}]');
  await tick();
  assert.deepStrictEqual(window.__rendered, ['new'], 'stale token rendered');
  assert.deepStrictEqual(window.lookupEntries, [{ w: 'new' }]);

  // 失败：当前令牌上报，旧令牌不报。
  window.__fushiRenderToken = 3;
  eval(${jsonEncode(script(token: 3, url: url3, afterEntriesJs: record))});
  window.__fushiRenderToken = 4;
  eval(${jsonEncode(script(token: 4, url: url4, afterEntriesJs: record))});
  fail(${jsonEncode(url3)});
  fail(${jsonEncode(url4)});
  await tick(); await tick();
  assert.deepStrictEqual(calls, [['popupEntriesFetchFailed', 4, 'blocked']]);
  assert.deepStrictEqual(window.__rendered, ['new'], 'failure must not render');
  console.log('all assertions passed');
})().catch((e) => { console.error(e); process.exit(1); });
''';
    final Directory dir = Directory.systemTemp.createTempSync(
      'popup_entries_fetch_',
    );
    try {
      final File file = File('${dir.path}${Platform.pathSeparator}glue.js')
        ..writeAsStringSync(harness);
      final ProcessResult result = await Process.run(nodeExe, <String>[
        file.path,
      ]);
      expect(
        result.exitCode,
        0,
        reason: 'stdout:\n${result.stdout}\nstderr:\n${result.stderr}',
      );
      expect(result.stdout.toString(), contains('all assertions passed'));
    } finally {
      dir.deleteSync(recursive: true);
    }
  });
}

/// Resolve a usable `node` executable, returning null when none is on PATH.
String? _resolveNode() {
  final List<String> candidates = Platform.isWindows
      ? <String>['node.exe', 'node']
      : <String>['node'];
  for (final String name in candidates) {
    try {
      final ProcessResult probe = Process.runSync(name, <String>['--version']);
      if (probe.exitCode == 0) return name;
    } on ProcessException {
      // try next candidate
    }
  }
  return null;
}
