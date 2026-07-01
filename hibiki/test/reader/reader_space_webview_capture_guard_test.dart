import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-1078 源码守卫：桌面 Windows 阅读器裸 Space 在 WebView2 抢走 OS 键盘焦点后，
/// 不再被 Chromium 默认 scrollByPage 吞掉，而是走「JS 捕获 → callHandler → Dart 解析」
/// 的既有范式（与 onSwipe/onWheelPaginate 同款），交回 resolveReaderSpaceOverride 判成
/// 有声书播放/暂停或翻页。
///
/// 该链路涉 WebView2 + 平台键盘转发，widget 测试照不到真实按键落 DOM，故用源码扫描
/// 钉死接线不回退：① 内容层注入 keydown 监听裸 Space；② preventDefault 掐掉浏览器默认
/// 滚屏；③ 经 callHandler('onSpaceKey') 回传；④ Dart 注册 onSpaceKey handler；⑤ handler
/// 经 _resolveWebViewSpaceAction 走 resolveReaderSpaceOverride 统一解析。
void main() {
  final File webview =
      File('lib/src/pages/implementations/reader_hibiki/webview.part.dart');
  final File caret =
      File('lib/src/pages/implementations/reader_hibiki/caret.part.dart');

  /// 折叠所有空白（含换行/多空格）为单空格，令断言匹配「真实 token 序列」而非精确
  /// 格式（换行、缩进重排不会误伤守卫）。
  String squash(String s) => s.replaceAll(RegExp(r'\s+'), ' ');

  test('webview.part.dart：内容层 keydown 捕获裸 Space + preventDefault + callHandler',
      () {
    expect(webview.existsSync(), isTrue,
        reason: 'webview.part.dart 不存在，路径变了须更新守卫');
    final String src = webview.readAsStringSync();
    final String flat = squash(src);

    // ① 注入 keydown 监听。
    expect(flat, contains("document.addEventListener('keydown'"),
        reason: '必须在内容层注入 keydown 监听拦截裸 Space');

    // 定位 keydown 监听体作断言窗口，避免误命中别处的 preventDefault / callHandler。
    final int start = flat.indexOf("document.addEventListener('keydown'");
    expect(start, greaterThanOrEqualTo(0));
    final String body = flat.substring(start, start + 700);

    // ② 只拦裸 Space：判 key===' ' 且放行带修饰键的组合。
    expect(body, contains("e.key !== ' '"),
        reason: '必须按 key===空格 判定，只拦裸 Space');
    expect(
      body.contains('e.ctrlKey') &&
          body.contains('e.shiftKey') &&
          body.contains('e.altKey') &&
          body.contains('e.metaKey'),
      isTrue,
      reason: 'Ctrl/Shift/Alt/Meta+Space 必须放行（尊重改键语义），不得吞掉',
    );

    // 文本框 / contenteditable / IME composing 里的空格放行。
    expect(body.contains('isComposing'), isTrue,
        reason: 'IME composing 里的空格不得拦（打字输入）');
    expect(body.contains('isContentEditable'), isTrue,
        reason: 'contenteditable 里的空格不得拦');

    // ③ preventDefault 掐掉浏览器默认 scrollByPage。
    expect(body.contains('e.preventDefault()'), isTrue,
        reason: '必须 preventDefault 掐掉 Chromium 默认滚屏');

    // ④ 经 callHandler('onSpaceKey') 回传 Dart。
    expect(body.contains("callHandler('onSpaceKey')"), isTrue,
        reason: "必须经 callHandler('onSpaceKey') 回传 Dart 解析");

    // Dart 侧注册 onSpaceKey handler。
    expect(flat, contains("handlerName: 'onSpaceKey'"),
        reason: 'Dart 必须注册 onSpaceKey handler 接收回传');
    expect(flat, contains('_resolveWebViewSpaceAction()'),
        reason: 'handler 必须经 _resolveWebViewSpaceAction 解析动作');
  });

  test(
      'caret.part.dart：裸 Space 解析走 resolveReaderSpaceOverride + reader scope 回落',
      () {
    final String src = caret.readAsStringSync();
    final String flat = squash(src);

    expect(flat, contains('ShortcutAction? _resolveWebViewSpaceAction()'),
        reason: '必须有 _resolveWebViewSpaceAction 解析裸 Space');
    final int start = flat.indexOf('_resolveWebViewSpaceAction()');
    final String body = flat.substring(start, start + 600);
    expect(body.contains('resolveReaderSpaceOverride('), isTrue,
        reason: '裸 Space 必须交 resolveReaderSpaceOverride 判有声书覆写');
    expect(body.contains('hasActiveAudiobook: _hasActiveAudiobook'), isTrue,
        reason: '有声书激活判据必须用 _hasActiveAudiobook（与键盘焦点路径同源）');
    expect(body.contains('ShortcutScope.reader'), isTrue,
        reason: '非有声书态必须回落 reader scope 裸 Space 绑定（默认翻页），行为不变');
  });
}
