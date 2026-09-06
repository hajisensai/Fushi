// BUG-2190 源码守卫：远程制卡（浏览器扩展 /api/mine）的外字嵌入链路两端都得在场。
//
// 用户卡片（AnkiDroid 截图）释义里「［参考］」「［参照］」压住正文——外字退化成 alt 文本
// 的两层根因：
//   ① 扩展 content.js 从不设 `window.embedMedia`，popup.js 只能把外字导出成 alt 文本；
//   ② 就算导出了 `<img src="fushi_dict_N.ext">`，服务端 `_AppModelRemoteLookupService`
//      的 mineEntry / mineImmersion 也从不 `writeDictionaryMediaCache`，repo 读不到字节。
// 两端任一漏掉，卡片上就没有外字。app 内入口（dictionary_popup_webview /
// overlay_bridge_handlers）都是「制卡前先落缓存」，远程入口必须同一步骤。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('远程 mineEntry / mineImmersion 制卡前先落词典媒体缓存（BUG-2190）', () {
    final String src = File('lib/src/models/app_model.dart').readAsStringSync();
    final int cls = src.indexOf('class _AppModelRemoteLookupService');
    expect(cls, greaterThan(0), reason: '远程查词/制卡 service 类应仍在 app_model.dart');
    final String body = src.substring(cls);

    final int mineEntry = body.indexOf('Future<RemoteMineResult> mineEntry({');
    final int mineImmersion =
        body.indexOf('Future<RemoteMineResult> mineImmersion(');
    expect(mineEntry, greaterThan(0));
    expect(mineImmersion, greaterThan(0));

    String methodBody(int start) {
      final int next = body.indexOf('\n  @override', start + 1);
      return body.substring(start, next < 0 ? body.length : next);
    }

    final String entryBody = methodBody(mineEntry);
    final String immersionBody = methodBody(mineImmersion);
    expect(entryBody,
        contains("writeDictionaryMediaCache(fields['dictionaryMedia']"),
        reason: 'mineEntry 制卡前必须把 fields.dictionaryMedia 落进 Anki 媒体缓存');
    expect(immersionBody,
        contains("writeDictionaryMediaCache(payload.fields['dictionaryMedia']"),
        reason: 'mineImmersion 三条沉浸分支最终都走 repo 渲染，同样要先落缓存');
    // 落缓存必须在 repo 创建/制卡之前（顺序守卫：缓存在前，repo 才读得到）。
    expect(entryBody.indexOf('writeDictionaryMediaCache'),
        lessThan(entryBody.indexOf('createAnkiRepository()')));
    expect(immersionBody.indexOf('writeDictionaryMediaCache'),
        lessThan(immersionBody.indexOf('createAnkiRepository()')));
  });

  test('扩展 content.js 渲染弹窗前置 window.embedMedia = true（三镜像）', () {
    for (final String path in <String>[
      'assets/browser_extension/content.js',
      '../tools/browser-extension/content.js',
    ]) {
      final String src = File(path).readAsStringSync();
      final int render = src.indexOf('function fushiRenderEntries(');
      expect(render, greaterThan(0), reason: '$path 应含 fushiRenderEntries');
      final int renderPopup = src.indexOf('window.renderPopup()', render);
      expect(renderPopup, greaterThan(render));
      final String between = src.substring(render, renderPopup);
      expect(between, contains('window.embedMedia = true;'),
          reason: '$path 必须在 renderPopup 之前把 embedMedia 设真，'
              '否则 popup.js 把外字导出成 alt 文本（BUG-2190）');
    }
  });
}
