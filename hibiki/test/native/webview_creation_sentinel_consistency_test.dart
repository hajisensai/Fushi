import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-904 跨文件字面量一致守卫：WebView2 实例创建失败的 sentinel。
///
/// `flutter_inappwebview_windows` fork 在 native 实例创建失败时，经 onReceivedError
/// 合成的 [WebResourceError] 描述里携带 `kInAppWebViewCreationFailedSentinel` 前缀；
/// reader（`kReaderWebViewCreationFailedSentinel`）凭**相同字面量**前缀区分「实例创建
/// 失败」与普通页面加载错误，只对前者走可见恢复（toast + 退回书架）。
///
/// 这两个常量分处不同包、无共享定义，只靠字面量字符串对齐。任一处改了字面量、另一处
/// 没跟着改，reader 的恢复分支会静默失效（永远匹配不上）——本守卫从源码各自抽出字面量
/// 断言两者完全相等，改坏即红。
void main() {
  String read(String rel) {
    final File f = File(rel);
    expect(f.existsSync(), isTrue, reason: '文件不存在：$rel');
    return f.readAsStringSync().replaceAll('\r\n', '\n');
  }

  /// 从源码里抽出 `const String <name> = '<literal>';` 的字面量值。
  String extractConstString(String src, String constName) {
    final RegExp re = RegExp(
      r'const\s+String\s+' + RegExp.escape(constName) + r"\s*=\s*'([^']*)'",
    );
    final Match? m = re.firstMatch(src);
    expect(m, isNotNull, reason: '未找到常量定义：$constName');
    return m!.group(1)!;
  }

  test('reader 与 fork 的 WebView 创建失败 sentinel 字面量必须一致', () {
    final String readerSrc =
        read('lib/src/pages/implementations/reader_hibiki_page.dart');
    final String forkSrc = read(
      '../packages/flutter_inappwebview_windows/lib/src/in_app_webview/in_app_webview.dart',
    );

    final String readerSentinel =
        extractConstString(readerSrc, 'kReaderWebViewCreationFailedSentinel');
    final String forkSentinel =
        extractConstString(forkSrc, 'kInAppWebViewCreationFailedSentinel');

    expect(readerSentinel, isNotEmpty);
    expect(readerSentinel, equals(forkSentinel),
        reason: 'reader 与 fork 的 WebView 创建失败 sentinel 必须逐字相等，'
            '否则 reader 的可见恢复分支永远匹配不上');
  });
}
