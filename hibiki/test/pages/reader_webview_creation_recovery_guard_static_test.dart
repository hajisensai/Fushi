import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-904 源码守卫：阅读器正文 WebView native 实例创建失败时可见恢复，不再永久 spinner。
///
/// 根因：Windows 反复开关书后 native WebView2 实例创建失败抛
/// `Cannot create the InAppWebView instance!`。原 fork `CustomPlatformView.initialize`
/// 是未捕获 Future，失败被 UncaughtZone 静默吞掉 → `isInitialized` 永不置真 →
/// reader 永远渲染占位、`onWebViewCreated` 从不触发 → 唯一兜底超时也武装不上 →
/// 永久 spinner（与 BUG-437 表象同、机理不同）。
///
/// 修复链：①fork `custom_platform_view.dart` initialize 失败经 `onCreationError`
/// 冒泡；②fork `in_app_webview.dart` 把它合成带 [_sentinel] 的 WebResourceError 经
/// `onReceivedError` 转交上层；③reader 的 `onReceivedError` 命中 sentinel 时走与
/// `_initBook` 同款可见恢复（toast `reader_open_failed` + `Navigator.pop`），普通页面
/// 加载错误（不带 sentinel）不触发恢复。
///
/// 守卫断言修复结构在位（仿 reader_init_hang_recovery_guard_static_test）。删任一即红。
void main() {
  const String sentinel = 'HIBIKI_INAPPWEBVIEW_CREATION_FAILED';

  String read(String rel) {
    final File f = File(rel);
    expect(f.existsSync(), isTrue, reason: '文件不存在：$rel');
    return f.readAsStringSync().replaceAll('\r\n', '\n');
  }

  test('fork CustomPlatformView 暴露 onCreationError 且失败路径不再静默吞', () {
    final String src = read(
        '../packages/flutter_inappwebview_windows/lib/src/in_app_webview/custom_platform_view.dart');

    expect(src.contains('onCreationError'), isTrue,
        reason: 'CustomPlatformView 必须暴露 onCreationError 让失败冒泡');
    // initialize 失败不再裸 fire-and-forget：initState 里挂 catchError 调 onCreationError。
    expect(src.contains('.catchError('), isTrue,
        reason: 'initState 必须捕获 initialize 失败（不再逃逸 UncaughtZone）');
    expect(src.contains('widget.onCreationError?.call'), isTrue,
        reason: '捕获后必须把失败冒泡给上层');
    // initialize 失败路径必须 completeError 解放 dispose 等待者。
    expect(src.contains('completeError('), isTrue,
        reason: 'initialize 失败路径必须 completeError（dispose await-gate 不挂起）');
  });

  test('fork in_app_webview 把创建失败合成 sentinel error 经 onReceivedError 转交', () {
    final String src = read(
        '../packages/flutter_inappwebview_windows/lib/src/in_app_webview/in_app_webview.dart');

    expect(src.contains('kInAppWebViewCreationFailedSentinel ='), isTrue,
        reason: '必须定义创建失败 sentinel 常量');
    expect(src.contains(sentinel), isTrue,
        reason: 'sentinel 字面量必须与 reader 端一致');
    expect(src.contains('onCreationError: _onCreationError'), isTrue,
        reason: 'CustomPlatformView 必须挂上失败回调');
    final int handlerIdx = src.indexOf('void _onCreationError(');
    expect(handlerIdx, greaterThan(-1), reason: '必须有 _onCreationError 处理器');
    final String handler = src.substring(handlerIdx);
    expect(handler.contains('onReceivedError'), isTrue,
        reason: '失败必须经 onReceivedError 转交上层');
  });

  test('reader onReceivedError 命中 sentinel 走 toast + pop 恢复', () {
    final String webviewPart =
        read('lib/src/pages/implementations/reader_hibiki/webview.part.dart');
    final String readerPage =
        read('lib/src/pages/implementations/reader_hibiki_page.dart');

    // reader 端 sentinel 常量与字面量。
    expect(
        readerPage.contains('kReaderWebViewCreationFailedSentinel =') &&
            readerPage.contains(sentinel),
        isTrue,
        reason: 'reader 必须定义与 fork 一致的 sentinel 常量');

    final int recvIdx = webviewPart.indexOf('onReceivedError:');
    expect(recvIdx, greaterThan(-1));
    // 取 onReceivedError 回调起始一段，断言 sentinel 命中分支在普通加载错误处理之前。
    final String block = webviewPart.substring(recvIdx, recvIdx + 900);
    expect(block.contains('kReaderWebViewCreationFailedSentinel'), isTrue,
        reason: 'onReceivedError 必须先判 sentinel 区分创建失败');
    expect(
        block.contains('HibikiToast.show(msg: t.reader_open_failed)'), isTrue,
        reason: '命中创建失败必须提示用户打开失败');
    expect(block.contains('Navigator.of(context).pop()'), isTrue,
        reason: '命中创建失败必须退回书架，不让 spinner 永挂');
    expect(block.contains('if (!mounted) return;'), isTrue,
        reason: 'setState/Navigator 前必须 mounted 守卫');
  });
}
