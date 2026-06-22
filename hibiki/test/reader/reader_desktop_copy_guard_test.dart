import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-402 源码守卫：阅读器桌面 Windows 复制兼容层接线不得回退。
///
/// 复制链路涉 WebView2 + 平台键盘转发，widget 测试照不到真实复制，故这里用源码
/// 扫描钉死三件事：① 键事件处理调用纯谓词 readerShouldHandleDesktopCopy 且门控
/// isWindowsPlatform；② 取的是浏览器原生 getSelection（window.getSelection），
/// **不是** hoshiSelection 查词选区；③ 命中后写系统剪贴板 Clipboard.setData。
void main() {
  final File caret =
      File('lib/src/pages/implementations/reader_hibiki/caret.part.dart');
  final File scripts = File('lib/src/reader/reader_selection_scripts.dart');

  test('caret.part.dart：Ctrl+C → 谓词门控 Windows + 取原生选区 + 写剪贴板', () {
    expect(caret.existsSync(), isTrue, reason: 'caret.part.dart 不存在，路径变了须更新守卫');
    final String src = caret.readAsStringSync();

    // ① 走纯谓词，且门控 Windows。
    expect(src, contains('readerShouldHandleDesktopCopy('),
        reason: '复制手势判定必须走纯谓词 readerShouldHandleDesktopCopy');
    expect(src, contains('isWindows: isWindowsPlatform'),
        reason: '必须门控 isWindowsPlatform（移动/mac 原生 copy 本就 work）');

    // ② + ③ 经 helper 取原生选区写剪贴板。
    expect(src, contains('_copyNativeSelectionToClipboard'),
        reason: '命中复制手势必须调 _copyNativeSelectionToClipboard');
    expect(src, contains('Clipboard.setData'),
        reason: '复制必须写系统剪贴板 Clipboard.setData');
    expect(src, contains('nativeSelectionTextInvocation'),
        reason: '必须取浏览器原生选区，不碰 hoshiSelection 查词选区');
  });

  test('reader_selection_scripts.dart：取 window.getSelection 而非 hoshiSelection',
      () {
    final String src = scripts.readAsStringSync();
    final int start = src.indexOf('nativeSelectionTextInvocation');
    expect(start, greaterThanOrEqualTo(0),
        reason: '缺 nativeSelectionTextInvocation');
    // invocation 方法体里必须是浏览器原生 getSelection。
    final String body = src.substring(start, start + 200);
    expect(body, contains('window.getSelection'), reason: '复制取的是浏览器原生选区');
    expect(body.contains('hoshiSelection'), isFalse,
        reason: '不得用 hoshiSelection 查词选区（BUG-368 注释，是另一套）');
  });
}
